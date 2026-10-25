import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/api.dart';
import '../../app/models.dart';

/// Playback position expressed in meeting time (seconds from the start of the recording).
class PlaybackState {
  const PlaybackState({
    this.segment,
    this.playing = false,
    this.loading = false,
    this.positionSec = 0,
    this.speed = 1.0,
    this.error,
  });

  final SegmentBrief? segment;
  final bool playing;
  final bool loading;

  /// Absolute meeting time of the playhead.
  final double positionSec;
  final double speed;
  final String? error;

  bool get hasAudio => segment != null;

  double get segmentStart => segment?.startOffsetSec ?? 0;
  double get segmentEnd => segmentStart + (segment?.durationSec ?? 0);

  PlaybackState copyWith({
    SegmentBrief? segment,
    bool? playing,
    bool? loading,
    double? positionSec,
    double? speed,
    String? error,
    bool clearError = false,
  }) {
    return PlaybackState(
      segment: segment ?? this.segment,
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      positionSec: positionSec ?? this.positionSec,
      speed: speed ?? this.speed,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Plays one segment at a time from a locally cached copy; tapping an utterance in another
/// segment swaps the file. Segment audio comes from GET /meetings/{id}/segments/{sid}/audio.
class PlaybackController extends Notifier<PlaybackState> {
  final AudioPlayer _player = AudioPlayer();
  MeetingDetail? _meeting;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  PlaybackState build() {
    _subs.add(_player.positionStream.listen((pos) {
      if (!ref.mounted || state.segment == null) return;
      state = state.copyWith(positionSec: state.segmentStart + pos.inMilliseconds / 1000);
    }));
    _subs.add(_player.playerStateStream.listen((ps) {
      if (!ref.mounted) return;
      final done = ps.processingState == ProcessingState.completed;
      state = state.copyWith(playing: ps.playing && !done);
      if (done) _advance();
    }));
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
      _subs.clear();
      _player.dispose();
    });
    return const PlaybackState();
  }

  /// Give the controller the meeting whose segments it should play. Safe to call repeatedly.
  void attach(MeetingDetail meeting) {
    if (_meeting != null && _meeting!.id != meeting.id) {
      _player.stop();
      state = const PlaybackState();
    }
    _meeting = meeting;
  }

  Future<File> _cacheFile(String meetingId, String segmentId) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/audio/$meetingId/$segmentId.mp3');
  }

  /// Start playing at an absolute meeting time.
  Future<void> playAt(double sec) async {
    final meeting = _meeting;
    if (meeting == null) return;
    final seg = meeting.segmentAt(sec);
    if (seg == null) return;
    try {
      if (state.segment?.id != seg.id) {
        state = state.copyWith(segment: seg, loading: true, clearError: true);
        final file = await _cacheFile(meeting.id, seg.id);
        await ref.read(apiProvider).downloadSegmentAudio(meeting.id, seg.id, file);
        await _player.setFilePath(file.path);
        await _player.setSpeed(state.speed);
      }
      if (!ref.mounted) return;
      final offset = (sec - seg.startOffsetSec).clamp(0.0, double.infinity);
      await _player.seek(Duration(milliseconds: (offset * 1000).round()));
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, positionSec: sec);
      await _player.play();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(loading: false, error: '재생 실패: $e');
    }
  }

  Future<void> toggle() async {
    if (state.segment == null) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> seekTo(double sec) async {
    final seg = state.segment;
    if (seg == null) return;
    if (sec < seg.startOffsetSec || sec >= state.segmentEnd) {
      await playAt(sec);
      return;
    }
    await _player.seek(Duration(milliseconds: ((sec - seg.startOffsetSec) * 1000).round()));
    state = state.copyWith(positionSec: sec);
  }

  Future<void> cycleSpeed() async {
    final next = switch (state.speed) {
      1.0 => 1.25,
      1.25 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    await _player.setSpeed(next);
    state = state.copyWith(speed: next);
  }

  Future<void> _advance() async {
    final meeting = _meeting;
    final seg = state.segment;
    if (meeting == null || seg == null) return;
    final next = meeting.segments.where((s) => s.index == seg.index + 1).firstOrNull;
    if (next == null) {
      if (ref.mounted) state = state.copyWith(playing: false);
      return;
    }
    await playAt(next.startOffsetSec);
  }

  Future<void> stop() async {
    await _player.stop();
    state = const PlaybackState();
  }
}

final playbackProvider =
    NotifierProvider.autoDispose<PlaybackController, PlaybackState>(PlaybackController.new);
