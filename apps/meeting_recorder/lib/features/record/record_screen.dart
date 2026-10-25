import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/models.dart';
import '../../app/theme.dart';
import '../meeting/chat_view.dart';
import '../meeting/meeting_screen.dart';
import 'live_client.dart';
import 'recording_controller.dart';

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final _title = TextEditingController();
  final _captionScroll = ScrollController();
  bool _summaryOpen = false;
  int _lastLineCount = 0;

  @override
  void dispose() {
    _title.dispose();
    _captionScroll.dispose();
    super.dispose();
  }

  Future<void> _bookmark() async {
    final ok = await ref.read(recordingProvider.notifier).addBookmark();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ok ? '중요 표시를 남겼습니다' : '중요 표시에 실패했습니다'),
        duration: const Duration(seconds: 1),
      ));
  }

  void _followCaptions(int count) {
    if (count == _lastLineCount) return;
    _lastLineCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_captionScroll.hasClients) {
        _captionScroll.animateTo(_captionScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingProvider);
    final ctrl = ref.read(recordingProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recording = state.phase == RecordingPhase.recording;
    final busy = state.phase == RecordingPhase.starting || state.phase == RecordingPhase.stopping;
    final finished = state.phase == RecordingPhase.finished;
    final idle = state.phase == RecordingPhase.idle;
    final showLive = state.live && (recording || state.phase == RecordingPhase.stopping || finished);
    _followCaptions(state.liveLines.length);

    return PopScope(
      canPop: !recording && !busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('녹음'),
          actions: [
            if (state.meetingId != null && (recording || finished))
              IconButton(
                tooltip: 'AI에게 질문',
                icon: const Icon(Icons.auto_awesome),
                onPressed: () => showChatSheet(context, state.meetingId!, recording: recording),
              ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (idle || finished) ...[
                  TextField(
                    controller: _title,
                    enabled: idle,
                    decoration: const InputDecoration(
                      hintText: '제목 (비워 두면 AI가 지어 줍니다)',
                      prefixIcon: Icon(Icons.edit_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TemplatePicker(
                    value: state.template,
                    enabled: idle || finished,
                    onChanged: ctrl.setTemplate,
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    value: state.live,
                    onChanged: idle || finished ? ctrl.setLive : null,
                    title: const Text('실시간 받아쓰기'),
                    subtitle: const Text('녹음하면서 바로 글자로 보여 주고, 몇 분마다 요약합니다. '
                        '무압축으로 저장해 업로드 용량이 커집니다(분당 약 \$0.017 추가).'),
                  ),
                ],
                _ClockRow(state: state, compact: showLive),
                if (showLive)
                  Expanded(
                    child: _LivePanel(
                      state: state,
                      scroll: _captionScroll,
                      summaryOpen: _summaryOpen,
                      onToggleSummary: () => setState(() => _summaryOpen = !_summaryOpen),
                    ),
                  )
                else
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(height: 64, child: _LevelBars(level: recording ? state.level : 0, active: recording)),
                        const SizedBox(height: 16),
                        Text(_statusText(state),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                if (state.segments.isNotEmpty) _UploadRow(state: state),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(state.error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _SideAction(
                      icon: Icons.star_border_rounded,
                      label: state.bookmarkCount == 0 ? '중요 표시' : '중요 ${state.bookmarkCount}',
                      enabled: recording,
                      onTap: _bookmark,
                    ),
                    _RecordButton(
                      recording: recording,
                      busy: busy,
                      onTap: () {
                        if (recording) {
                          ctrl.stop();
                        } else {
                          if (finished) {
                            ctrl.reset();
                            _title.clear();
                          }
                          ctrl.start(_title.text);
                        }
                      },
                    ),
                    finished && state.meetingId != null
                        ? _SideAction(
                            icon: Icons.article_outlined,
                            label: '노트 보기',
                            enabled: true,
                            onTap: () {
                              final id = state.meetingId!;
                              ctrl.reset();
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute<void>(builder: (_) => MeetingScreen(meetingId: id)),
                              );
                            },
                          )
                        : _SideAction(
                            icon: Icons.auto_awesome_outlined,
                            label: 'AI 질문',
                            enabled: recording && state.meetingId != null,
                            onTap: () => showChatSheet(context, state.meetingId!, recording: true),
                          ),
                  ],
                ),
                if (state.failed > 0)
                  TextButton(onPressed: ctrl.retryFailed, child: const Text('실패한 업로드 다시 시도')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _statusText(RecordingState s) => switch (s.phase) {
        RecordingPhase.idle => '버튼을 누르면 녹음이 시작되고, 몇 분 단위로 서버에 올라갑니다',
        RecordingPhase.starting => '시작하는 중…',
        RecordingPhase.recording => '녹음 중 · 중요한 순간엔 별표를 눌러 두세요',
        RecordingPhase.stopping => '마지막 부분을 올리는 중…',
        RecordingPhase.finished => '녹음 종료 · 서버가 받아쓰기와 노트를 만들고 있습니다',
      };
}

class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({required this.value, required this.enabled, required this.onChanged});

  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: NoteTemplate.all.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final t = NoteTemplate.all[i];
          final selected = t.key == value;
          return ChoiceChip(
            avatar: Icon(templateIcon(t.key), size: 16,
                color: selected ? scheme.onPrimary : scheme.primary),
            label: Text(t.label),
            tooltip: t.description,
            selected: selected,
            showCheckmark: false,
            selectedColor: scheme.primary,
            labelStyle: TextStyle(color: selected ? scheme.onPrimary : scheme.onSurface),
            onSelected: enabled ? (_) => onChanged(t.key) : null,
          );
        },
      ),
    );
  }
}

class _ClockRow extends StatelessWidget {
  const _ClockRow({required this.state, required this.compact});

  final RecordingState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clock = Text(
      formatClock(state.elapsed.inMilliseconds / 1000),
      style: (compact ? theme.textTheme.headlineMedium : theme.textTheme.displayLarge)?.copyWith(
        fontWeight: FontWeight.w300,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (!compact) {
      return Padding(padding: const EdgeInsets.only(top: 16), child: Center(child: clock));
    }
    final (label, color) = switch (state.liveStatus) {
      LiveStatus.ready => ('실시간 받아쓰기 중', scheme.primary),
      LiveStatus.connecting => ('연결 중…', scheme.outline),
      LiveStatus.reconnecting => ('다시 연결하는 중…', scheme.tertiary),
      LiveStatus.failed => ('실시간 받아쓰기 꺼짐', scheme.error),
      LiveStatus.off => (state.phase == RecordingPhase.finished ? '녹음 종료' : '', scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          if (state.isRecording) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ],
          clock,
          const SizedBox(width: 12),
          Expanded(child: SizedBox(height: 28, child: _LevelBars(level: state.isRecording ? state.level : 0, active: state.isRecording, count: 16))),
          const SizedBox(width: 8),
          Tooltip(
            message: state.liveMessage ?? label,
            child: Text(label, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

class _LivePanel extends StatelessWidget {
  const _LivePanel({
    required this.state,
    required this.scroll,
    required this.summaryOpen,
    required this.onToggleSummary,
  });

  final RecordingState state;
  final ScrollController scroll;
  final bool summaryOpen;
  final VoidCallback onToggleSummary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summaries = state.liveSummaries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: scheme.primaryContainer.withValues(alpha: 0.55),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: summaries.isEmpty ? null : onToggleSummary,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.bolt, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text('실시간 요약', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    if (summaries.isNotEmpty)
                      Text('${summaries.length}', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (summaries.length > 1)
                      Icon(summaryOpen ? Icons.expand_less : Icons.expand_more, color: scheme.outline),
                  ]),
                  const SizedBox(height: 6),
                  if (summaries.isEmpty)
                    Text('대화가 쌓이면 몇 분마다 요약이 여기에 나타납니다.',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
                  else
                    for (final s in summaryOpen ? summaries : [summaries.last]) _SummaryWindow(item: s),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: state.liveLines.isEmpty
              ? Center(
                  child: Text(
                    state.liveStatus == LiveStatus.failed
                        ? (state.liveMessage ?? '실시간 받아쓰기를 쓸 수 없습니다. 녹음은 계속됩니다.')
                        : '말하면 여기에 바로 받아 적습니다',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.outline),
                  ),
                )
              : ListView.builder(
                  controller: scroll,
                  itemCount: state.liveLines.length,
                  itemBuilder: (context, i) {
                    final line = state.liveLines[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(formatClock(line.atSec),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                          ),
                          Expanded(
                            child: Text(
                              line.text,
                              style: TextStyle(
                                height: 1.45,
                                color: line.isFinal ? scheme.onSurface : scheme.outline,
                                fontStyle: line.isFinal ? FontStyle.normal : FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SummaryWindow extends StatelessWidget {
  const _SummaryWindow({required this.item});

  final LiveSummaryItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatClock(item.startSec)} – ${formatClock(item.endSec)}',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          for (final b in item.bullets)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('• $b', style: const TextStyle(fontSize: 13.5, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.recording, required this.busy, required this.onTap});

  final bool recording;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = recording ? scheme.error : scheme.primary;
    return Semantics(
      button: true,
      label: recording ? '녹음 정지' : '녹음 시작',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 88,
        height: 88,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.12)),
        padding: const EdgeInsets.all(9),
        child: Material(
          color: busy ? scheme.surfaceContainerHighest : color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: busy ? null : onTap,
            child: Center(
              child: busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Icon(recording ? Icons.stop_rounded : Icons.mic_rounded, color: Colors.white, size: 34),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  const _SideAction({required this.icon, required this.label, required this.enabled, required this.onTap});

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? scheme.onSurface : scheme.outline.withValues(alpha: 0.5);
    return SizedBox(
      width: 92,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(onPressed: enabled ? onTap : null, icon: Icon(icon), iconSize: 24),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 12, color: color), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rolling input-level bars (a small ring buffer of recent levels).
class _LevelBars extends StatefulWidget {
  const _LevelBars({required this.level, required this.active, this.count = 28});

  final double level;
  final bool active;
  final int count;

  @override
  State<_LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<_LevelBars> {
  late final List<double> _history = List<double>.filled(widget.count, 0, growable: true);

  @override
  void didUpdateWidget(covariant _LevelBars old) {
    super.didUpdateWidget(old);
    if (widget.active) {
      _history.removeAt(0);
      _history.add(widget.level);
    } else if (old.active) {
      _history.fillRange(0, _history.length, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < _history.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 4,
                height: math.max(4, h * (0.15 + 0.85 * _history[i])),
                decoration: BoxDecoration(
                  color: widget.active
                      ? scheme.primary.withValues(alpha: 0.35 + 0.65 * _history[i])
                      : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.state});

  final RecordingState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(state.failed > 0 ? Icons.error_outline : Icons.cloud_done_outlined,
              size: 16, color: state.failed > 0 ? scheme.error : scheme.outline),
          const SizedBox(width: 6),
          Text('서버 업로드 ${state.uploaded}/${state.segments.length}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
