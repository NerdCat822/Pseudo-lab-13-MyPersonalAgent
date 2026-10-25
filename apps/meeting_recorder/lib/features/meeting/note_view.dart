import 'package:flutter/material.dart';

import '../../app/models.dart';
import '../../app/theme.dart';

typedef EditText = Future<String?> Function(String title, String initial, {bool multiline});

/// The 노트 tab: the template output, live summaries and bookmarks.
class NoteView extends StatefulWidget {
  const NoteView({
    super.key,
    required this.detail,
    required this.summary,
    required this.editText,
    required this.onSave,
    required this.onEditLiveSummary,
    required this.onJump,
    required this.onDeleteBookmark,
    required this.onChangeTemplate,
  });

  final MeetingDetail detail;
  final MeetingSummary? summary;
  final EditText editText;

  /// Persist hand edits: keys are summary fields (see PUT /meetings/{id}/summary).
  final Future<void> Function(Map<String, dynamic> fields) onSave;
  final Future<void> Function(LiveSummaryItem item, String text) onEditLiveSummary;
  final ValueChanged<double> onJump;
  final ValueChanged<Bookmark> onDeleteBookmark;
  final VoidCallback onChangeTemplate;

  @override
  State<NoteView> createState() => _NoteViewState();
}

class _NoteViewState extends State<NoteView> {
  final Set<int> _done = {};

  MeetingSummary? get s => widget.summary;

  Future<void> _editList(String field, List<String> items, int index, String title) async {
    final v = await widget.editText(title, items[index], multiline: true);
    if (v == null) return;
    final next = [...items];
    v.trim().isEmpty ? next.removeAt(index) : next[index] = v.trim();
    await widget.onSave({field: next});
  }

  Future<void> _editSectionBullet(int si, int bi) async {
    final sections = s!.sections;
    final v = await widget.editText(sections[si].heading, sections[si].bullets[bi], multiline: true);
    if (v == null) return;
    final next = [
      for (var i = 0; i < sections.length; i++)
        if (i != si)
          sections[i].toJson()
        else
          NoteSection(
            heading: sections[i].heading,
            bullets: [
              for (var j = 0; j < sections[i].bullets.length; j++)
                if (j != bi) sections[i].bullets[j] else if (v.trim().isNotEmpty) v.trim(),
            ],
          ).toJson(),
    ];
    await widget.onSave({'sections': next});
  }

  Future<void> _editAction(int index) async {
    final items = s!.actionItems;
    final v = await widget.editText('할 일', items[index].what, multiline: true);
    if (v == null) return;
    final next = [
      for (var i = 0; i < items.length; i++)
        if (i != index)
          items[i].toJson()
        else if (v.trim().isNotEmpty)
          ActionItem(what: v.trim(), who: items[i].who, due: items[i].due).toJson(),
    ];
    await widget.onSave({'action_items': next});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = widget.detail;
    final children = <Widget>[];
    final template = NoteTemplate.of(s?.template ?? d.template);

    children.add(Row(
      children: [
        ActionChip(
          avatar: Icon(templateIcon(template.key), size: 16, color: scheme.primary),
          label: Text('${template.label} ▾'),
          tooltip: '다른 템플릿으로 다시 정리',
          onPressed: d.isDone || d.isFailed ? widget.onChangeTemplate : null,
        ),
        const SizedBox(width: 8),
        if (s?.edited == true) Text('직접 수정됨', style: TextStyle(fontSize: 12, color: scheme.outline)),
        const Spacer(),
        if (s != null) Text('길게 눌러 수정', style: TextStyle(fontSize: 11, color: scheme.outline)),
      ],
    ));

    if (s == null) {
      children.add(_Info(
        icon: d.isActive ? Icons.hourglass_top : Icons.notes,
        text: d.isActive
            ? (d.isRecording
                ? '녹음이 끝나면 ${template.label}을 만듭니다. 그동안 실시간 요약과 AI 질문을 쓸 수 있어요.'
                : '받아쓰기가 끝나면 ${template.label}을 만듭니다.')
            : '노트가 없습니다. 템플릿을 골라 다시 만들어 보세요.',
      ));
    } else {
      final sum = s!;
      if (sum.oneLine.isNotEmpty) {
        children.add(Card(
          color: scheme.primary,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onLongPress: () async {
              final v = await widget.editText('한 줄 요약', sum.oneLine, multiline: true);
              if (v != null && v.trim().isNotEmpty) await widget.onSave({'one_line': v.trim()});
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.auto_awesome, color: scheme.onPrimary.withValues(alpha: 0.9), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(sum.oneLine,
                      style: theme.textTheme.titleMedium?.copyWith(color: scheme.onPrimary, height: 1.4)),
                ),
              ]),
            ),
          ),
        ));
      }
      for (var si = 0; si < sum.sections.length; si++) {
        final sec = sum.sections[si];
        children.add(_Section(
          title: sec.heading,
          child: Column(children: [
            for (var bi = 0; bi < sec.bullets.length; bi++)
              _Bullet(text: sec.bullets[bi], onLongPress: () => _editSectionBullet(si, bi)),
          ]),
        ));
      }
      if (sum.keyPoints.isNotEmpty) {
        children.add(_Section(
          title: template.key == 'lecture' ? '복습할 내용' : '주요 내용',
          child: Column(children: [
            for (var i = 0; i < sum.keyPoints.length; i++)
              _Numbered(
                n: i + 1,
                text: sum.keyPoints[i],
                onLongPress: () => _editList('key_points', sum.keyPoints, i, '주요 내용'),
              ),
          ]),
        ));
      }
      if (sum.summary.isNotEmpty && sum.summary != sum.oneLine) {
        children.add(_Section(
          title: '상세 요약',
          child: InkWell(
            onLongPress: () async {
              final v = await widget.editText('상세 요약', sum.summary, multiline: true);
              if (v != null && v.trim().isNotEmpty) await widget.onSave({'summary': v.trim()});
            },
            child: Text(sum.summary, style: const TextStyle(height: 1.55)),
          ),
        ));
      }
      if (sum.decisions.isNotEmpty) {
        children.add(_Section(
          title: '결정사항',
          child: Column(children: [
            for (var i = 0; i < sum.decisions.length; i++)
              _Bullet(
                text: sum.decisions[i],
                icon: Icons.check_circle_outline,
                color: scheme.tertiary,
                onLongPress: () => _editList('decisions', sum.decisions, i, '결정사항'),
              ),
          ]),
        ));
      }
      if (sum.actionItems.isNotEmpty) {
        children.add(_Section(
          title: '할 일',
          child: Column(children: [
            for (var i = 0; i < sum.actionItems.length; i++)
              InkWell(
                onLongPress: () => _editAction(i),
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _done.contains(i),
                  onChanged: (_) => setState(() => _done.contains(i) ? _done.remove(i) : _done.add(i)),
                  title: Text(
                    sum.actionItems[i].what,
                    style: TextStyle(
                      decoration: _done.contains(i) ? TextDecoration.lineThrough : null,
                      color: _done.contains(i) ? scheme.outline : null,
                    ),
                  ),
                  subtitle: _actionMeta(sum.actionItems[i]),
                ),
              ),
          ]),
        ));
      }
      if (sum.keyTerms.isNotEmpty) {
        children.add(_Section(
          title: '핵심 용어',
          child: Column(children: [
            for (final t in sum.keyTerms)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(t.term, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t.explanation, style: const TextStyle(height: 1.4))),
                ]),
              ),
          ]),
        ));
      }
      if (sum.suggestions.isNotEmpty) {
        children.add(_Section(
          title: 'AI 제안',
          child: Column(children: [
            for (var i = 0; i < sum.suggestions.length; i++)
              _Bullet(
                text: sum.suggestions[i],
                icon: Icons.tips_and_updates_outlined,
                color: scheme.primary,
                onLongPress: () => _editList('suggestions', sum.suggestions, i, 'AI 제안'),
              ),
          ]),
        ));
      }
      if (sum.openQuestions.isNotEmpty) {
        children.add(_Section(
          title: template.key == 'lecture' ? '복습 질문' : '미해결 질문',
          child: Column(children: [
            for (var i = 0; i < sum.openQuestions.length; i++)
              _Bullet(
                text: sum.openQuestions[i],
                icon: Icons.help_outline,
                color: scheme.secondary,
                onLongPress: () => _editList('open_questions', sum.openQuestions, i, '질문'),
              ),
          ]),
        ));
      }
      if (sum.keywordCounts.isNotEmpty) {
        children.add(_Section(
          title: '자주 나온 단어',
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in sum.keywordCounts)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${k.word}  ${k.count}회'),
              ),
          ]),
        ));
      }
    }

    if (d.liveSummaries.isNotEmpty) {
      children.add(_Section(
        title: '실시간 요약 ${d.liveSummaries.length}',
        child: Column(children: [
          for (final w in d.liveSummaries)
            InkWell(
              onTap: () => widget.onJump(w.startSec),
              onLongPress: () async {
                final v = await widget.editText('실시간 요약', w.text, multiline: true);
                if (v != null && v.trim().isNotEmpty) await widget.onEditLiveSummary(w, v.trim());
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 96,
                    child: Text('${formatClock(w.startSec)}–${formatClock(w.endSec)}',
                        style: TextStyle(fontSize: 12, color: scheme.primary)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final b in w.bullets) Text('• $b', style: const TextStyle(height: 1.45))],
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ));
    }

    if (d.bookmarks.isNotEmpty) {
      children.add(_Section(
        title: '중요 표시 ${d.bookmarks.length}',
        child: Column(children: [
          for (final b in d.bookmarks)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.star_rounded, color: Colors.amber.shade600),
              title: Text(b.note?.isNotEmpty == true ? b.note! : '중요 표시'),
              subtitle: Text(formatClock(b.atSec)),
              trailing: const Icon(Icons.play_arrow_rounded),
              onTap: () => widget.onJump(b.atSec),
              onLongPress: () => widget.onDeleteBookmark(b),
            ),
        ]),
      ));
    }

    if (s != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('${template.label} · ${s!.model} · 누적 비용 \$${d.costUsd.toStringAsFixed(3)}',
            textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: c)],
    );
  }

  Widget? _actionMeta(ActionItem a) {
    final parts = [if (a.who.isNotEmpty) a.who, if (a.due.isNotEmpty) a.due];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text, this.icon, this.color, this.onLongPress});

  final String text;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null)
            Icon(icon, size: 18, color: color ?? scheme.primary)
          else
            Padding(
              padding: const EdgeInsets.only(top: 7, left: 4, right: 4),
              child: Container(width: 6, height: 6, decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle)),
            ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
        ]),
      ),
    );
  }
}

class _Numbered extends StatelessWidget {
  const _Numbered({required this.n, required this.text, this.onLongPress});

  final int n;
  final String text;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(7)),
            child: Text('$n', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
        ]),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(icon, color: scheme.outline),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))),
        ]),
      ),
    );
  }
}
