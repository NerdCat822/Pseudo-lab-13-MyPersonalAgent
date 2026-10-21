import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/models.dart';
import '../meeting/meeting_screen.dart';
import 'recording_controller.dart';

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingProvider);
    final ctrl = ref.read(recordingProvider.notifier);
    final theme = Theme.of(context);
    final recording = state.phase == RecordingPhase.recording;
    final busy = state.phase == RecordingPhase.starting || state.phase == RecordingPhase.stopping;

    return PopScope(
      canPop: !recording && !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('새 회의')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                enabled: state.phase == RecordingPhase.idle,
                decoration: const InputDecoration(
                  labelText: '회의 제목 (선택)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  formatClock(state.elapsed.inMilliseconds / 1000),
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: recording ? state.level : 0,
                minHeight: 10,
                borderRadius: BorderRadius.circular(5),
              ),
              const SizedBox(height: 8),
              Text(
                recording ? '입력 레벨' : statusText(state.phase),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              if (state.segments.isNotEmpty) _UploadList(state: state),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(state.error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              const Spacer(),
              if (state.phase == RecordingPhase.finished && state.meetingId != null)
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('결과 보기'),
                  onPressed: () {
                    final id = state.meetingId!;
                    ctrl.reset();
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(builder: (_) => MeetingScreen(meetingId: id)),
                    );
                  },
                ),
              if (state.failed > 0)
                TextButton(onPressed: ctrl.retryFailed, child: const Text('실패한 업로드 다시 시도')),
              const SizedBox(height: 12),
              SizedBox(
                height: 64,
                child: recording
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                        icon: const Icon(Icons.stop),
                        label: const Text('녹음 정지'),
                        onPressed: busy ? null : ctrl.stop,
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.mic),
                        label: Text(state.phase == RecordingPhase.finished ? '새로 녹음' : '녹음 시작'),
                        onPressed: busy
                            ? null
                            : () {
                                if (state.phase == RecordingPhase.finished) ctrl.reset();
                                ctrl.start(_title.text);
                              },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String statusText(RecordingPhase phase) => switch (phase) {
        RecordingPhase.idle => '녹음을 시작하면 세그먼트마다 서버로 올라갑니다',
        RecordingPhase.starting => '시작하는 중…',
        RecordingPhase.recording => '',
        RecordingPhase.stopping => '마지막 세그먼트 업로드 중…',
        RecordingPhase.finished => '녹음 종료. 서버가 전사·요약을 진행합니다',
      };
}

class _UploadList extends StatelessWidget {
  const _UploadList({required this.state});

  final RecordingState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('세그먼트 업로드 ${state.uploaded}/${state.segments.length}',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in state.segments)
              Chip(
                avatar: Icon(_icon(s.status), size: 16),
                label: Text('#${s.index} ${formatClock(s.durationSec)}'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }

  static IconData _icon(UploadStatus s) => switch (s) {
        UploadStatus.pending => Icons.schedule,
        UploadStatus.uploading => Icons.cloud_upload_outlined,
        UploadStatus.done => Icons.check_circle_outline,
        UploadStatus.failed => Icons.error_outline,
      };
}
