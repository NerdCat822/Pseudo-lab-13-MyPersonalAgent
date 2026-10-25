import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/api.dart';
import '../../app/models.dart';
import '../../app/settings.dart';
import 'live_client.dart';
import 'wav_writer.dart';

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

enum RecordingPhase { idle, starting, recording, stopping, finished }

class RecordingState {
  const RecordingState({
    this.meetingId,
    this.title,
    this.phase = RecordingPhase.idle,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.segments = const [],
    this.bookmarkCount = 0,
    this.error,
    this.template = 'meeting',
    this.live = true,
    this.liveStatus = LiveStatus.off,
    this.liveMessage,
    this.liveLines = const [],
    this.liveSummaries = const [],
  });

  final String? meetingId;
  final String? title;
  final RecordingPhase phase;
  final Duration elapsed;

  /// 0..1 input level for the meter.
  final double level;
  final List<SegmentUpload> segments;
  final int bookmarkCount;
  final String? error;
  final String template;

  /// 실시간 받아쓰기 for this recording (PCM stream + live captions socket).
  final bool live;
  final LiveStatus liveStatus;
  final String? liveMessage;
  final List<LiveLine> liveLines;
  final List<LiveSummaryItem> liveSummaries;

  int get uploaded => segments.where((s) => s.status == UploadStatus.done).length;
  int get failed => segments.where((s) => s.status == UploadStatus.failed).length;
  bool get allUploaded => segments.every((s) => s.status == UploadStatus.done);
  bool get isRecording => phase == RecordingPhase.recording;

  RecordingState copyWith({
    String? meetingId,
    String? title,
    RecordingPhase? phase,
    Duration? elapsed,
    double? level,
    List<SegmentUpload>? segments,
    int? bookmarkCount,
    String? error,
    bool clearError = false,
    String? template,
    bool? live,
    LiveStatus? liveStatus,
    String? liveMessage,
    bool clearLiveMessage = false,
    List<LiveLine>? liveLines,
    List<LiveSummaryItem>? liveSummaries,
  }) {
    return RecordingState(
      meetingId: meetingId ?? this.meetingId,
      title: title ?? this.title,
      phase: phase ?? this.phase,
      elapsed: elapsed ?? this.elapsed,
      level: level ?? this.level,
      segments: segments ?? this.segments,
      bookmarkCount: bookmarkCount ?? this.bookmarkCount,
      error: clearError ? null : (error ?? this.error),
      template: template ?? this.template,
      live: live ?? this.live,
      liveStatus: liveStatus ?? this.liveStatus,
      liveMessage: clearLiveMessage ? null : (liveMessage ?? this.liveMessage),
      liveLines: liveLines ?? this.liveLines,
      liveSummaries: liveSummaries ?? this.liveSummaries,
    );
  }
}

/// Records segments of `segmentSeconds`, uploads each one as soon as it closes, and sends
/// `finish` when the user stops.
///
/// Two capture modes:
/// * file (live off): AAC 48 kbps segments; the recorder restarts at each boundary.
/// * stream (live on): one PCM16 24 kHz stream feeds gapless WAV segments *and* the live
///   captions socket, so the microphone is opened once on every platform.
///
/// The upload queue lives in memory for now (persistent queue: issue #3).
class RecordingController extends Notifier<RecordingState> {
  static const liveRate = 24000;

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _ticker;
  Timer? _rotation;
  StreamSubscription<Amplitude>? _amplitude;
  StreamSubscription<Uint8List>? _pcmSub;
  Completer<void>? _pcmDone;
  DateTime? _startedAt;
  DateTime? _segmentStartedAt;
  int _nextIndex = 0;
  int _segmentCount = 0;
  Directory? _dir;
  Future<void> _uploadChain = Future.value();
  WavSegmentWriter? _writer;
  LiveClient? _liveClient;
  bool _downsample = false;
  DateTime _lastLevelAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _fileConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 48000,
    sampleRate: 44100,
    numChannels: 1,
    autoGain: true,
    noiseSuppress: true,
  );

  static RecordConfig _streamConfig(int rate) => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: rate,
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
      _pcmSub?.cancel();
      _liveClient?.dispose();
      _recorder.dispose();
    });
    final s = ref.read(settingsProvider).value ?? AppSettings.defaults;
    return RecordingState(template: s.defaultTemplate, live: s.liveCaptions);
  }

  MeetingApi get _api => ref.read(apiProvider);
  AppSettings get _settings => ref.read(settingsProvider).value ?? AppSettings.defaults;

  void setTemplate(String template) {
    if (state.phase == RecordingPhase.idle || state.phase == RecordingPhase.finished) {
      state = state.copyWith(template: template);
    }
  }

  void setLive(bool live) {
    if (state.phase == RecordingPhase.idle || state.phase == RecordingPhase.finished) {
      state = state.copyWith(live: live);
    }
  }

  double get elapsedSec => state.live && _writer != null
      ? _writer!.elapsedSec
      : (_startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inMilliseconds / 1000);

  Future<void> start(String? title) async {
    if (state.phase != RecordingPhase.idle && state.phase != RecordingPhase.finished) return;
    final template = state.template;
    final live = state.live;
    state = RecordingState(phase: RecordingPhase.starting, template: template, live: live);
    try {
      if (!await _recorder.hasPermission()) {
        throw Exception('마이크 권한이 없습니다');
      }
      final cleanTitle = (title ?? '').trim();
      final meeting = await _api.createMeeting(
        title: cleanTitle.isEmpty ? null : cleanTitle,
        template: template,
      );
      final docs = await getApplicationDocumentsDirectory();
      _dir = Directory('${docs.path}/recordings/${meeting.id}');
      await _dir!.create(recursive: true);
      _nextIndex = 0;
      _segmentCount = 0;
      _startedAt = DateTime.now();
      state = state.copyWith(
        meetingId: meeting.id,
        title: meeting.title,
        phase: RecordingPhase.recording,
        elapsed: Duration.zero,
        segments: const [],
        liveLines: const [],
        liveSummaries: const [],
        clearError: true,
      );
      if (live) {
        await _startStreamCapture(meeting.id);
      } else {
        await _startFileCapture();
      }
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        state = state.copyWith(elapsed: Duration(milliseconds: (elapsedSec * 1000).round()));
      });
    } catch (e) {
      await _recorder.stop().catchError((_) => null);
      _liveClient?.dispose();
      _liveClient = null;
      state = RecordingState(
        phase: RecordingPhase.idle,
        error: e.toString(),
        template: template,
        live: live,
      );
    }
  }

  // -- file mode -------------------------------------------------------------------------------

  Future<void> _startFileCapture() async {
    await _startFileSegment();
    _rotation = Timer.periodic(Duration(seconds: _settings.segmentSeconds), (_) => _rotate());
    _amplitude = _recorder.onAmplitudeChanged(const Duration(milliseconds: 250)).listen((a) {
      // dBFS: -160..0 → 0..1 with a usable range of -60..0.
      state = state.copyWith(level: ((a.current + 60) / 60).clamp(0.0, 1.0));
    });
  }

  Future<void> _startFileSegment() async {
    final path = '${_dir!.path}/${_nextIndex.toString().padLeft(3, '0')}.m4a';
    _segmentStartedAt = DateTime.now();
    await _recorder.start(_fileConfig, path: path);
  }

  /// Close the current file and open the next one. The gap is the recorder restart time.
  Future<void> _rotate() async {
    final closed = await _closeFileSegment();
    _nextIndex++;
    await _startFileSegment();
    if (closed != null) _enqueue(closed);
  }

  Future<SegmentUpload?> _closeFileSegment() async {
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

  // -- stream mode -----------------------------------------------------------------------------

  Future<void> _startStreamCapture(String meetingId) async {
    Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(_streamConfig(liveRate));
      _downsample = false;
    } catch (_) {
      stream = await _recorder.startStream(_streamConfig(liveRate * 2));
      _downsample = true;
    }
    _writer = WavSegmentWriter(
      directory: _dir!.path,
      sampleRate: liveRate,
      segmentSeconds: _settings.segmentSeconds,
    )..open();
    _pcmDone = Completer<void>();
    _pcmSub = stream.listen(
      _onPcm,
      onDone: () => _pcmDone?.complete(),
      onError: (Object e) => state = state.copyWith(error: '녹음 오류: $e'),
    );
    final settings = _settings;
    _liveClient = LiveClient(
      uriFor: () => settings.liveUri(meetingId, elapsedSec),
      token: settings.token,
      onEvent: _onLiveEvent,
      onStatus: (status, message) {
        state = state.copyWith(
          liveStatus: status,
          liveMessage: message,
          clearLiveMessage: message == null,
        );
      },
    );
    unawaited(_liveClient!.start());
  }

  void _onPcm(Uint8List chunk) {
    final pcm = _downsample ? downsample2(chunk) : chunk;
    final writer = _writer;
    if (writer == null || !writer.isOpen) return;
    for (final closed in writer.add(pcm)) {
      _enqueueClosed(closed);
    }
    _liveClient?.send(pcm);
    final now = DateTime.now();
    if (now.difference(_lastLevelAt).inMilliseconds >= 120) {
      _lastLevelAt = now;
      state = state.copyWith(level: pcmLevel(pcm));
    }
  }

  void _enqueueClosed(ClosedSegment c) {
    _enqueue(SegmentUpload(
      index: c.index,
      file: c.file,
      startOffsetSec: c.startSec,
      durationSec: c.durationSec,
    ));
  }

  void _onLiveEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'partial' || 'final':
        final id = '${e['id']}';
        final lines = [...state.liveLines];
        final i = lines.indexWhere((l) => l.id == id);
        final at = (e['at_sec'] as num?)?.toDouble() ?? elapsedSec;
        final text = '${e['text'] ?? ''}';
        final isFinal = e['type'] == 'final';
        if (i >= 0) {
          lines[i]
            ..text = text
            ..atSec = at
            ..isFinal = isFinal;
        } else if (text.isNotEmpty) {
          lines.add(LiveLine(id: id, atSec: at, text: text, isFinal: isFinal));
        }
        lines.sort((a, b) => a.atSec.compareTo(b.atSec));
        state = state.copyWith(liveLines: lines);
      case 'drop':
        state = state.copyWith(liveLines: state.liveLines.where((l) => l.id != '${e['id']}').toList());
      case 'summary':
        state = state.copyWith(liveSummaries: [...state.liveSummaries, LiveSummaryItem.fromJson(e)]);
      case 'error':
        state = state.copyWith(liveMessage: '${e['message'] ?? e['code']}');
    }
  }

  // -- uploads ---------------------------------------------------------------------------------

  void _enqueue(SegmentUpload seg) {
    _segmentCount++;
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

  // -- stop ------------------------------------------------------------------------------------

  Future<void> stop() async {
    if (state.phase != RecordingPhase.recording) return;
    state = state.copyWith(phase: RecordingPhase.stopping);
    _ticker?.cancel();
    _rotation?.cancel();
    await _amplitude?.cancel();
    final total = elapsedSec;
    if (state.live) {
      await _recorder.stop();
      await _pcmDone?.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      await _pcmSub?.cancel();
      final writer = _writer!;
      if (writer.elapsedSec == 0) writer.add(silencePcm(liveRate, 0.5));
      final last = writer.close();
      if (last != null) _enqueueClosed(last);
      _writer = null;
      await _liveClient?.stop();
      _liveClient = null;
    } else {
      final closed = await _closeFileSegment();
      if (closed != null) _enqueue(closed);
    }
    try {
      await _api.finish(state.meetingId!, segmentCount: _segmentCount, durationSec: total);
      state = state.copyWith(phase: RecordingPhase.finished, level: 0, clearError: true);
    } catch (e) {
      state = state.copyWith(phase: RecordingPhase.finished, level: 0, error: '종료 신호 실패: $e');
    }
  }

  /// "중요 표시": stamp the current elapsed time on the server (works while recording).
  Future<bool> addBookmark({String? note}) async {
    final id = state.meetingId;
    if (id == null || state.phase != RecordingPhase.recording) return false;
    try {
      await _api.addBookmark(id, elapsedSec, note: note);
      state = state.copyWith(bookmarkCount: state.bookmarkCount + 1);
      return true;
    } catch (e) {
      state = state.copyWith(error: '중요 표시 실패: $e');
      return false;
    }
  }

  void reset() {
    if (state.phase == RecordingPhase.recording || state.phase == RecordingPhase.stopping) return;
    state = RecordingState(template: state.template, live: state.live);
  }
}

final recordingProvider =
    NotifierProvider<RecordingController, RecordingState>(RecordingController.new);
