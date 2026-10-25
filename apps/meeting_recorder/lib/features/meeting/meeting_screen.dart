import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/api.dart';
import '../../app/models.dart';
import '../../app/theme.dart';
import 'chat_view.dart';
import 'note_export.dart';
import 'note_view.dart';
import 'playback_controller.dart';
import 'share_sheet.dart';

/// A note: header, then 노트 / 받아쓰기 / AI 질문 tabs, with playback at the bottom.
class MeetingScreen extends ConsumerStatefulWidget {
  const MeetingScreen({super.key, required this.meetingId, this.initialTab = 0});

  final String meetingId;
  final int initialTab;

  @override
  ConsumerState<MeetingScreen> createState() => _MeetingScreenState();
}

class _MeetingScreenState extends ConsumerState<MeetingScreen> {
  MeetingDetail? _detail;
  List<Utterance> _transcript = const [];
  List<LiveCaption> _captions = const [];
  MeetingSummary? _summary;
  String? _error;
  Timer? _poll;
  int _lastDone = -1;
  int _lastCaptions = -1;
  bool _hadSummary = false;
  late int _tab = widget.initialTab;
  String _filter = '';
  final Map<int, GlobalKey> _bubbleKeys = {};

  MeetingApi get _api => ref.read(apiProvider);

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
    try {
      final d = await _api.getMeeting(widget.meetingId);
      final transcript =
          d.segmentsDone != _lastDone || d.isDone ? await _api.transcript(widget.meetingId) : _transcript;
      final captions = d.liveCaptionCount != _lastCaptions ? await _api.liveCaptions(widget.meetingId) : _captions;
      MeetingSummary? summary = _summary;
      if (d.hasSummary && (!_hadSummary || summary == null)) {
        summary = await _api.summary(widget.meetingId);
      } else if (!d.hasSummary) {
        summary = null;
      }
      if (!mounted) return;
      setState(() {
        _detail = d;
        _transcript = transcript;
        _captions = captions;
        _summary = summary;
        _hadSummary = d.hasSummary;
        _lastDone = d.segmentsDone;
        _lastCaptions = d.liveCaptionCount;
        _error = null;
      });
      // The player bar (which keeps the autoDispose provider alive) exists only after this
      // frame, so attach the meeting once the tree has rebuilt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(playbackProvider.notifier).attach(d);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guard(Future<void> Function() job) async {
    try {
      await job();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<String?> _editText(String title, String initial, {bool multiline = false}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 8 : 1,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('저장')),
        ],
      ),
    );
  }

  Future<void> _rename() async {
    final d = _detail!;
    final v = await _editText('제목', d.title ?? '');
    if (v == null || v.trim().isEmpty) return;
    await _guard(() async {
      await _api.patchMeeting(d.id, title: v.trim());
      await _refresh();
    });
  }

  Future<void> _moveFolder() async {
    final d = _detail!;
    final folders = await _api.folders().catchError((_) => <FolderInfo>[]);
    if (!mounted) return;
    final ctrl = TextEditingController();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('폴더로 이동', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f.name),
                trailing: f.name == d.folder ? const Icon(Icons.check) : Text('${f.count}'),
                onTap: () => Navigator.pop(ctx, f.name),
              ),
            if (d.folder != null)
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('폴더에서 빼기'),
                onTap: () => Navigator.pop(ctx, ''),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: TextField(
                controller: ctrl,
                decoration: const InputDecoration(hintText: '새 폴더 이름', prefixIcon: Icon(Icons.create_new_folder_outlined)),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await _guard(() async {
      if (choice.isEmpty) {
        await _api.patchMeeting(d.id, clearFolder: true);
      } else {
        await _api.patchMeeting(d.id, folder: choice);
      }
      await _refresh();
      _snack(choice.isEmpty ? '폴더에서 뺐습니다' : '‘$choice’ 폴더로 옮겼습니다');
    });
  }

  Future<void> _delete() async {
    final d = _detail!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('노트 삭제'),
        content: Text('‘${d.displayTitle}’의 받아쓰기, 요약, 질문 내역과 녹음 파일을 서버에서 지웁니다. 되돌릴 수 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await ref.read(playbackProvider.notifier).stop();
      await _api.deleteMeeting(d.id);
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _changeTemplate() async {
    final d = _detail!;
    final current = _summary?.template ?? d.template;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('템플릿 바꾸기', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('받아쓰기는 그대로 두고 노트만 다시 만듭니다'),
            ),
            for (final t in NoteTemplate.all)
              ListTile(
                leading: Icon(templateIcon(t.key)),
                title: Text(t.label),
                subtitle: Text(t.description),
                trailing: t.key == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, t.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _guard(() async {
      await _api.resummarize(d.id, template: picked);
      _hadSummary = false;
      _summary = null;
      await _refresh();
      _snack('‘${NoteTemplate.of(picked).label}’(으)로 다시 정리하는 중입니다');
    });
  }

  Future<void> _saveSummary(Map<String, dynamic> fields) => _guard(() async {
        final s = await _api.editSummary(widget.meetingId, fields);
        if (mounted) setState(() => _summary = s);
        if (fields.containsKey('title')) await _refresh();
      });

  Future<void> _utteranceActions(Utterance u) async {
    final d = _detail!;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.play_arrow), title: const Text('여기서부터 듣기'), onTap: () => Navigator.pop(ctx, 'play')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('받아쓰기 수정'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(leading: const Icon(Icons.badge_outlined), title: Text('‘${u.speakerName}’ 이름 바꾸기'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.copy), title: const Text('복사'), onTap: () => Navigator.pop(ctx, 'copy')),
        ]),
      ),
    );
    switch (action) {
      case 'play':
        _jumpTo(u.startSec, switchTab: false);
      case 'edit':
        final v = await _editText('받아쓰기 수정', u.text, multiline: true);
        if (v != null && v.trim().isNotEmpty && v.trim() != u.text) {
          await _guard(() async {
            await _api.editUtterance(d.id, u.id, v.trim());
            _lastDone = -1;
            await _refresh();
          });
        }
      case 'rename':
        final sp = d.speakers.where((s) => s.id == u.speakerId).firstOrNull;
        if (sp == null) return;
        final v = await _editText('화자 이름', sp.displayName);
        if (v != null && v.trim().isNotEmpty && v.trim() != sp.displayName) {
          await _guard(() async {
            await _api.renameSpeaker(d.id, sp.id, v.trim());
            _lastDone = -1;
            await _refresh();
          });
        }
      case 'copy':
        await Clipboard.setData(ClipboardData(text: u.text));
        _snack('복사했습니다');
    }
  }

  void _jumpTo(double sec, {bool switchTab = true}) {
    if (switchTab && _tab != 1) setState(() => _tab = 1);
    ref.read(playbackProvider.notifier).playAt(sec);
    // Bring the utterance being played into view once the transcript tab is built.
    Utterance? target;
    for (final u in _transcript) {
      if (u.startSec <= sec + 0.5) target = u;
    }
    if (target == null) return;
    final key = _bubbleKeys[target.id];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300));
      }
    });
  }

  NoteExportData get _export => NoteExportData(
        detail: _detail!,
        summary: _summary,
        utterances: _transcript,
        captions: _captions,
      );

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final scheme = Theme.of(context).colorScheme;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!)),
      );
    }
    final header = <Widget>[
      if (_tab != 2) _HeaderCard(detail: d, summary: _summary, onTitleTap: _rename),
      if (d.isActive || d.isFailed) ...[
        const SizedBox(height: 10),
        _StatusCard(detail: d, onRetry: () => _guard(() async {
              await _api.retry(d.id);
              await _refresh();
            })),
      ],
      if (_error != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: scheme.error))),
      const SizedBox(height: 12),
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(value: 0, label: Text('노트'), icon: Icon(Icons.article_outlined)),
          ButtonSegment(
            value: 1,
            label: Text('받아쓰기 ${_transcript.isNotEmpty ? _transcript.length : _captions.length}'),
            icon: const Icon(Icons.forum_outlined),
          ),
          const ButtonSegment(value: 2, label: Text('AI 질문'), icon: Icon(Icons.auto_awesome_outlined)),
        ],
        selected: {_tab},
        onSelectionChanged: (s) => setState(() => _tab = s.first),
      ),
      const SizedBox(height: 12),
    ];

    final Widget body;
    if (_tab == 2) {
      body = Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Column(children: header)),
        Expanded(child: ChatView(meetingId: d.id, recording: d.isRecording, onJump: (s) => _jumpTo(s))),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            ...header,
            if (_tab == 0)
              NoteView(
                detail: d,
                summary: _summary,
                editText: _editText,
                onSave: _saveSummary,
                onEditLiveSummary: (item, text) => _guard(() async {
                  await _api.editLiveSummary(d.id, item.id, text);
                  await _refresh();
                }),
                onJump: (s) => _jumpTo(s),
                onDeleteBookmark: (b) => _guard(() async {
                  await _api.deleteBookmark(d.id, b.id);
                  await _refresh();
                }),
                onChangeTemplate: _changeTemplate,
              )
            else
              _TranscriptTab(
                detail: d,
                transcript: _transcript,
                captions: _captions,
                filter: _filter,
                onFilter: (v) => setState(() => _filter = v),
                onActions: _utteranceActions,
                keyFor: (id) => _bubbleKeys.putIfAbsent(id, GlobalKey.new),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Text(d.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          IconButton(
            tooltip: '공유',
            icon: const Icon(Icons.ios_share),
            onPressed: () => showShareSheet(context, _api, _export),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'rename':
                  await _rename();
                case 'folder':
                  await _moveFolder();
                case 'template':
                  await _changeTemplate();
                case 'refresh':
                  await _refresh();
                case 'delete':
                  await _delete();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit), title: Text('제목 바꾸기'))),
              const PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.drive_file_move_outline), title: Text('폴더로 이동'))),
              PopupMenuItem(
                value: 'template',
                enabled: d.isDone || d.isFailed,
                child: const ListTile(leading: Icon(Icons.dashboard_customize_outlined), title: Text('템플릿 바꾸기')),
              ),
              const PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.refresh), title: Text('새로고침'))),
              const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('삭제'))),
            ],
          ),
        ],
      ),
      body: Column(children: [Expanded(child: body), const _PlayerBar()]),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Header / status

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.detail, required this.summary, required this.onTitleTap});

  final MeetingDetail detail;
  final MeetingSummary? summary;
  final VoidCallback onTitleTap;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final participants = d.speakers.map((s) => s.displayName).join(', ');
    final keywords = summary?.topics ?? d.keywords;
    Widget tag(String text, Color color, {IconData? icon}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
            Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (d.category != null) ...[tag(d.category!, categoryColor(d.category, scheme)), const SizedBox(width: 6)],
              if (d.folder != null) tag(d.folder!, scheme.secondary, icon: Icons.folder_outlined),
              const Spacer(),
              Text(
                '${dateHeader(d.createdAt)} ${timeOfDay(d.createdAt)}'
                '${d.durationSec != null ? ' · ${formatClock(d.durationSec!)}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ]),
            const SizedBox(height: 8),
            InkWell(
              onTap: onTitleTap,
              child: Text(d.displayTitle, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (participants.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.people_outline, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(participants,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ]),
            ],
            if (keywords.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final k in keywords)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('#$k', style: TextStyle(fontSize: 12, color: scheme.primary)),
                  ),
              ]),
            ],
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
    final scheme = Theme.of(context).colorScheme;
    final total = d.expectedSegments ?? d.segmentsTotal;
    final text = d.isFailed
        ? '${statusLabel(d.status)} · ${d.failedStep ?? ''}: ${d.error ?? ''}'
        : d.isRecording
            ? '녹음 중 · 받아쓴 구간 ${d.segmentsDone}/${d.segmentsTotal}'
            : '${statusLabel(d.status)} · 구간 ${d.segmentsDone}/$total';
    return Card(
      color: d.isFailed ? scheme.errorContainer : scheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (d.isActive) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              if (d.isFailed) Icon(Icons.error_outline, color: scheme.error, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
              if (d.isFailed) TextButton(onPressed: onRetry, child: const Text('다시 시도')),
            ]),
            if (d.isActive && !d.isRecording) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: total == 0 ? null : d.progress, borderRadius: BorderRadius.circular(4)),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// 받아쓰기 탭

class _TranscriptTab extends ConsumerWidget {
  const _TranscriptTab({
    required this.detail,
    required this.transcript,
    required this.captions,
    required this.filter,
    required this.onFilter,
    required this.onActions,
    required this.keyFor,
  });

  final MeetingDetail detail;
  final List<Utterance> transcript;
  final List<LiveCaption> captions;
  final String filter;
  final ValueChanged<String> onFilter;
  final ValueChanged<Utterance> onActions;
  final GlobalKey Function(int utteranceId) keyFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final scheme = Theme.of(context).colorScheme;
    final q = filter.trim();
    final speakerIndex = {for (var i = 0; i < detail.speakers.length; i++) detail.speakers[i].id: i};
    final rows = <Widget>[
      TextField(
        onChanged: onFilter,
        decoration: InputDecoration(
          hintText: '받아쓰기에서 찾기',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          suffixText: q.isEmpty
              ? null
              : '${transcript.isNotEmpty ? transcript.where((u) => u.text.contains(q)).length : captions.where((c) => c.text.contains(q)).length}건',
        ),
      ),
      const SizedBox(height: 12),
    ];

    if (transcript.isEmpty && captions.isNotEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(Icons.bolt, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('실시간 자막입니다. 녹음 파일 받아쓰기가 끝나면 화자별 대화로 바뀝니다.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ));
      for (final c in captions.where((c) => q.isEmpty || c.text.contains(q))) {
        rows.add(InkWell(
          onTap: () => ref.read(playbackProvider.notifier).playAt(c.atSec),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 52, child: Text(formatClock(c.atSec), style: TextStyle(fontSize: 12, color: scheme.outline))),
              Expanded(child: Text(c.text, style: const TextStyle(height: 1.45))),
            ]),
          ),
        ));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    }

    final shown = q.isEmpty ? transcript : transcript.where((u) => u.text.contains(q) || u.speakerName.contains(q)).toList();
    if (shown.isEmpty) {
      rows.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            transcript.isEmpty
                ? (detail.isActive ? '녹음 구간이 받아써지면 여기에 대화가 쌓입니다.' : '발화가 없습니다.')
                : '검색 결과가 없습니다.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ));
    }
    final bookmarks = [...detail.bookmarks]..sort((a, b) => a.atSec.compareTo(b.atSec));
    var bi = 0;
    for (final u in shown) {
      while (q.isEmpty && bi < bookmarks.length && bookmarks[bi].atSec <= u.startSec) {
        rows.add(_BookmarkMarker(bookmark: bookmarks[bi]));
        bi++;
      }
      final current = playback.hasAudio && playback.positionSec >= u.startSec && playback.positionSec < u.endSec;
      rows.add(_Bubble(
        key: keyFor(u.id),
        utterance: u,
        color: speakerColor(speakerIndex[u.speakerId] ?? 0),
        highlighted: current,
        onTap: () => ref.read(playbackProvider.notifier).playAt(u.startSec),
        onLongPress: () => onActions(u),
      ));
    }
    if (playback.error != null) {
      rows.add(Padding(padding: const EdgeInsets.only(top: 8), child: Text(playback.error!, style: TextStyle(color: scheme.error))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.utterance,
    required this.color,
    required this.highlighted,
    required this.onTap,
    required this.onLongPress,
  });

  final Utterance utterance;
  final Color color;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final u = utterance;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final initial = u.speakerName.isEmpty ? '?' : u.speakerName.characters.last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.15),
          child: Text(initial, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(u.speakerName, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13)),
              const SizedBox(width: 6),
              Text(formatClock(u.startSec), style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
            ]),
            const SizedBox(height: 4),
            Material(
              color: highlighted ? color.withValues(alpha: 0.14) : (theme.cardTheme.color ?? scheme.surface),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
                topLeft: Radius.circular(4),
              ),
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text(u.text, style: const TextStyle(height: 1.45)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _BookmarkMarker extends StatelessWidget {
  const _BookmarkMarker({required this.bookmark});

  final Bookmark bookmark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 10),
      child: Row(children: [
        Expanded(child: Divider(color: Colors.amber.shade300)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Icon(Icons.star_rounded, size: 16, color: Colors.amber.shade600),
            const SizedBox(width: 4),
            Text(
              '${formatClock(bookmark.atSec)}${bookmark.note?.isNotEmpty == true ? ' · ${bookmark.note}' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
        Expanded(child: Divider(color: Colors.amber.shade300)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Player bar

class _PlayerBar extends ConsumerWidget {
  const _PlayerBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    if (!p.hasAudio) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(playbackProvider.notifier);
    final start = p.segmentStart;
    final end = p.segmentEnd > start ? p.segmentEnd : start + 1;
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 12, 6),
          child: Row(children: [
            IconButton.filled(
              onPressed: p.loading ? null : ctrl.toggle,
              icon: p.loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(p.playing ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(value: p.positionSec.clamp(start, end), min: start, max: end, onChanged: ctrl.seekTo),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(formatClock(p.positionSec), style: Theme.of(context).textTheme.bodySmall),
                    Text('구간 ${(p.segment?.index ?? 0) + 1} · ${formatClock(end)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                  ]),
                ),
              ]),
            ),
            TextButton(onPressed: ctrl.cycleSpeed, child: Text('${p.speed}x')),
            IconButton(onPressed: ctrl.stop, icon: const Icon(Icons.close)),
          ]),
        ),
      ),
    );
  }
}
