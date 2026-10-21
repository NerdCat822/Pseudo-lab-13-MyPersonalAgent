import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/api.dart';
import '../../app/settings.dart';

enum UploadStatus { pending, uploading, done, failed }

class SegmentUpload {
  SegmentUpload({
    required this.index,
    required this.file,
    required this.startOffsetSec,
    required this.durationSec,
    this.status = UploadStatus.pending,
    this.attempts = 0,
    this.error,
  });

  final int index;
  final File file;
  final double startOffsetSec;
  final double durationSec;
  UploadStatus status;
  int attempts;
  String? error;
}

class RecordingState {
  const RecordingState({
    this.meetingId,
    this.title,
    this.phase = RecordingPhase.idle,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.segments = const [],
    this.error,
  });

  final String? meetingId;
  final String? title;
  final RecordingPhase phase;
  final Duration elapsed;

  /// 0..1 input level for the meter.
  final double level;
  final List<SegmentUpload> segments;
  final String? error;

  int get uploaded => segments.where((s) => s.status == UploadStatus.done).length;
  int get failed => segments.where((s) => s.status == UploadStatus.failed).length;
  bool get allUploaded => segments.every((s) => s.status == UploadStatus.done);

  RecordingState copyWith({
    String? meetingId,
    String? title,
    RecordingPhase? phase,
    Duration? elapsed,
    double? level,
    List<SegmentUpload>? segments,
    String? error,
    bool clearError = false,
  }) {
    return RecordingState(
      meetingId: meetingId ?? this.meetingId,
      title: title ?? this.title,
      phase: phase ?? this.phase,
      elapsed: elapsed ?? this.elapsed,
      level: level ?? this.level,
      segments: segments ?? this.segments,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

enum RecordingPhase { idle, starting, recording, stopping, finished }

/// Records AAC segments of `segmentSeconds`, uploads each one as soon as it closes,
/// and sends `finish` when the user stops. Uploads retry with backoff; the queue lives in
/// memory for now (the drift-backed persistent queue is W1 work).
class RecordingController extends Notifier<RecordingState> {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _ticker;
  Timer? _rotation;
  StreamSubscription<Amplitude>? _amplitude;
  DateTime? _startedAt;
  DateTime? _segmentStartedAt;
  int _nextIndex = 0;
  Directory? _dir;
  Future<void> _uploadChain = Future.value();

  static const _config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 48000,
    sampleRate: 44100,
    numChannels: 1,
    autoGain: true,
    noiseSuppress: true,
  );

  @override
  RecordingState build() {
    ref.onDispose(() {
      _ticker?.cancel();
      _rotation?.cancel();
      _amplitude?.cancel();
      _recorder.dispose();
    });
    return const RecordingState();
  }

  MeetingApi get _api => ref.read(apiProvider);

  Future<void> start(String? title) async {
    if (state.phase != RecordingPhase.idle && state.phase != RecordingPhase.finished) return;
    state = const RecordingState(phase: RecordingPhase.starting);
    try {
      if (!await _recorder.hasPermission()) {
        throw Exception('마이크 권한이 없습니다');
      }
      final cleanTitle = (title ?? '').trim();
      final meeting = await _api.createMeeting(cleanTitle.isEmpty ? null : cleanTitle);
      final docs = await getApplicationDocumentsDirectory();
      _dir = Directory('${docs.path}/recordings/${meeting.id}');
      await _dir!.create(recursive: true);
      _nextIndex = 0;
      _startedAt = DateTime.now();
      await _startSegment();
      state = state.copyWith(
        meetingId: meeting.id,
        title: meeting.title,
        phase: RecordingPhase.recording,
        elapsed: Duration.zero,
        segments: const [],
        clearError: true,
      );
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        state = state.copyWith(elapsed: DateTime.now().difference(_startedAt!));
      });
      final seconds = ref.read(settingsProvider).value?.segmentSeconds ?? 600;
      _rotation = Timer.periodic(Duration(seconds: seconds), (_) => _rotate());
      _amplitude = _recorder.onAmplitudeChanged(const Duration(milliseconds: 250)).listen((a) {
        // dBFS: -160..0 → 0..1 with a usable range of -60..0.
        final level = ((a.current + 60) / 60).clamp(0.0, 1.0);
        state = state.copyWith(level: level);
      });
    } catch (e) {
      await _recorder.stop().catchError((_) => null);
      state = RecordingState(phase: RecordingPhase.idle, error: e.toString());
    }
  }

  Future<void> _startSegment() async {
    final path = '${_dir!.path}/${_nextIndex.toString().padLeft(3, '0')}.m4a';
    _segmentStartedAt = DateTime.now();
    await _recorder.start(_config, path: path);
  }

  /// Close the current file and open the next one. The gap is the recorder restart time.
  Future<void> _rotate() async {
    final closed = await _closeSegment();
    _nextIndex++;
    await _startSegment();
    if (closed != null) _enqueue(closed);
  }

  Future<SegmentUpload?> _closeSegment() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final startedAt = _segmentStartedAt ?? DateTime.now();
    return SegmentUpload(
      index: _nextIndex,
      file: File(path),
      startOffsetSec: startedAt.difference(_startedAt!).inMilliseconds / 1000,
      durationSec: DateTime.now().difference(startedAt).inMilliseconds / 1000,
    );
  }

  void _enqueue(SegmentUpload seg) {
    state = state.copyWith(segments: [...state.segments, seg]);
    _uploadChain = _uploadChain.then((_) => _upload(seg));
  }

  Future<void> _upload(SegmentUpload seg) async {
    final meetingId = state.meetingId!;
    for (var attempt = 1; attempt <= 3; attempt++) {
      seg.attempts = attempt;
      seg.status = UploadStatus.uploading;
      _touch();
      try {
        await _api.uploadSegment(
          meetingId: meetingId,
          index: seg.index,
          startOffsetSec: seg.startOffsetSec,
          durationSec: seg.durationSec,
          file: seg.file,
        );
        seg.status = UploadStatus.done;
        seg.error = null;
        _touch();
        return;
      } on ApiException catch (e) {
        seg.error = e.message;
        // Server-side rejections won't change on retry.
        if (e.statusCode != null && e.statusCode! < 500 && e.statusCode != 408) break;
      } catch (e) {
        seg.error = e.toString();
      }
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
    seg.status = UploadStatus.failed;
    _touch();
  }

  void _touch() => state = state.copyWith(segments: [...state.segments]);

  Future<void> retryFailed() async {
    for (final seg in state.segments.where((s) => s.status == UploadStatus.failed)) {
      seg.status = UploadStatus.pending;
      _uploadChain = _uploadChain.then((_) => _upload(seg));
    }
    _touch();
  }

  Future<void> stop() async {
    if (state.phase != RecordingPhase.recording) return;
    state = state.copyWith(phase: RecordingPhase.stopping);
    _ticker?.cancel();
    _rotation?.cancel();
    await _amplitude?.cancel();
    final closed = await _closeSegment();
    if (closed != null) _enqueue(closed);
    final total = DateTime.now().difference(_startedAt!).inMilliseconds / 1000;
    try {
      await _api.finish(state.meetingId!, segmentCount: _nextIndex + 1, durationSec: total);
      state = state.copyWith(phase: RecordingPhase.finished, level: 0, clearError: true);
    } catch (e) {
      state = state.copyWith(phase: RecordingPhase.finished, level: 0, error: '종료 신호 실패: $e');
    }
  }

  void reset() {
    if (state.phase == RecordingPhase.recording) return;
    state = const RecordingState();
  }
}

final recordingProvider =
    NotifierProvider<RecordingController, RecordingState>(RecordingController.new);
