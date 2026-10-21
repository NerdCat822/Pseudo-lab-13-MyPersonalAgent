import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/api.dart';
import '../../app/models.dart';

/// Detail view: polls the meeting while it is being processed, then shows the
/// speaker-labelled transcript and the summary.
class MeetingScreen extends ConsumerStatefulWidget {
  const MeetingScreen({super.key, required this.meetingId});

  final String meetingId;

  @override
  ConsumerState<MeetingScreen> createState() => _MeetingScreenState();
}

class _MeetingScreenState extends ConsumerState<MeetingScreen> {
  MeetingDetail? _detail;
  List<Utterance> _transcript = const [];
  MeetingSummary? _summary;
  String? _error;
  Timer? _poll;
  int _lastDone = -1;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_detail?.isActive ?? true) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = ref.read(apiProvider);
    try {
      final d = await api.getMeeting(widget.meetingId);
      final needTranscript = d.segmentsDone != _lastDone || d.isDone;
      final transcript = needTranscript ? await api.transcript(widget.meetingId) : _transcript;
      final summary = d.hasSummary && _summary == null ? await api.summary(widget.meetingId) : _summary;
      if (!mounted) return;
      setState(() {
        _detail = d;
        _transcript = transcript;
        _summary = summary;
        _lastDone = d.segmentsDone;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _rename(Speaker speaker) async {
    final ctrl = TextEditingController(text: speaker.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('화자 이름'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('저장')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == speaker.displayName) return;
    try {
      await ref.read(apiProvider).renameSpeaker(widget.meetingId, speaker.id, name);
      _lastDone = -1; // force transcript reload
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _retry() async {
    try {
      await ref.read(apiProvider).retry(widget.meetingId);
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  String _asMarkdown() {
    final d = _detail!;
    final b = StringBuffer('# ${d.title ?? '회의'}\n\n');
    final s = _summary;
    if (s != null) {
      b.writeln('## 요약\n\n${s.summary}\n');
      if (s.decisions.isNotEmpty) b.writeln('## 결정사항\n\n${s.decisions.map((e) => '- $e').join('\n')}\n');
      if (s.actionItems.isNotEmpty) {
        b.writeln('## 액션 아이템\n');
        for (final a in s.actionItems) {
          final who = a.who.isEmpty ? '' : ' (${a.who}';
          final due = a.due.isEmpty ? (who.isEmpty ? '' : ')') : '${who.isEmpty ? ' (' : ', '}${a.due})';
          b.writeln('- [ ] ${a.what}$who$due');
        }
        b.writeln();
      }
    }
    b.writeln('## 전사\n');
    for (final u in _transcript) {
      b.writeln('[${formatClock(u.startSec)}] **${u.speakerName}**: ${u.text}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.title ?? '회의'),
        actions: [
          if (d != null && _transcript.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () => SharePlus.instance.share(ShareParams(text: _asMarkdown())),
            ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: d == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _StatusCard(detail: d, onRetry: _retry),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (_summary != null) ...[
                    const SizedBox(height: 16),
                    _SummaryCard(summary: _summary!),
                  ],
                  const SizedBox(height: 16),
                  Text('전사 (${_transcript.length})', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_transcript.isEmpty)
                    Text(
                      d.isActive ? '세그먼트가 전사되면 여기에 표시됩니다.' : '발화가 없습니다.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  for (final u in _transcript)
                    _UtteranceTile(
                      utterance: u,
                      onTapSpeaker: () {
                        final sp = d.speakers.where((s) => s.id == u.speakerId).firstOrNull;
                        if (sp != null) _rename(sp);
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.detail, required this.onRetry});

  final MeetingDetail detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final total = d.expectedSegments ?? d.segmentsTotal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(label: Text(statusLabel(d.status))),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    [
                      if (d.durationSec != null) formatClock(d.durationSec!),
                      '세그먼트 ${d.segmentsDone}/$total',
                      if (d.costUsd > 0) '\$${d.costUsd.toStringAsFixed(3)}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (d.isActive) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: total == 0 ? null : d.progress),
            ],
            if (d.isFailed) ...[
              const SizedBox(height: 8),
              Text('${d.failedStep ?? ''}: ${d.error ?? ''}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onRetry, child: const Text('다시 시도')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MeetingSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget section(String title, List<String> items) => items.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                for (final i in items) Text('• $i'),
              ],
            ),
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('요약', style: t.titleMedium),
            const SizedBox(height: 8),
            Text(summary.summary),
            section('결정사항', summary.decisions),
            section(
              '액션 아이템',
              [
                for (final a in summary.actionItems)
                  '${a.what}${a.who.isEmpty ? '' : ' — ${a.who}'}${a.due.isEmpty ? '' : ' (${a.due})'}',
              ],
            ),
            section('주제', summary.topics),
            section('미해결 질문', summary.openQuestions),
          ],
        ),
      ),
    );
  }
}

class _UtteranceTile extends StatelessWidget {
  const _UtteranceTile({required this.utterance, required this.onTapSpeaker});

  final Utterance utterance;
  final VoidCallback onTapSpeaker;

  @override
  Widget build(BuildContext context) {
    final u = utterance;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(formatClock(u.startSec),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: onTapSpeaker,
                  child: Text(u.speakerName,
                      style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary)),
                ),
                Text(u.text),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
