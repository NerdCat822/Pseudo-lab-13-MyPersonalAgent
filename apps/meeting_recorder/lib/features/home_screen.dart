import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/api.dart';
import '../app/models.dart';
import '../app/theme.dart';
import 'import/import_screen.dart';
import 'meeting/meeting_screen.dart';
import 'record/record_screen.dart';
import 'settings_screen.dart';

const categories = ['전체', '업무', '개인', '상담', '학습', '기타'];

class HomeFilter {
  const HomeFilter({this.query = '', this.category = '전체', this.folder});

  final String query;
  final String category;
  final String? folder;

  HomeFilter copyWith({String? query, String? category, String? folder, bool clearFolder = false}) => HomeFilter(
        query: query ?? this.query,
        category: category ?? this.category,
        folder: clearFolder ? null : (folder ?? this.folder),
      );
}

class HomeFilterNotifier extends Notifier<HomeFilter> {
  @override
  HomeFilter build() => const HomeFilter();

  void setQuery(String q) => state = state.copyWith(query: q);
  void setCategory(String c) => state = state.copyWith(category: c);
  void setFolder(String? f) => state = state.copyWith(folder: f, clearFolder: f == null);
}

final homeFilterProvider = NotifierProvider<HomeFilterNotifier, HomeFilter>(HomeFilterNotifier.new);

final meetingsProvider = FutureProvider.autoDispose<List<MeetingItem>>((ref) {
  final f = ref.watch(homeFilterProvider);
  return ref.watch(apiProvider).listMeetings(
        query: f.query.trim().isEmpty ? null : f.query.trim(),
        category: f.category == '전체' ? null : f.category,
        folder: f.folder,
      );
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    ref.invalidate(meetingsProvider);
  }

  Future<void> _pickFolder() async {
    final current = ref.read(homeFilterProvider).folder;
    final folders = await ref.read(apiProvider).folders().catchError((_) => <FolderInfo>[]);
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('폴더', style: TextStyle(fontWeight: FontWeight.w700))),
          ListTile(
            leading: const Icon(Icons.all_inbox_outlined),
            title: const Text('모든 노트'),
            trailing: current == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final f in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f.name),
              trailing: f.name == current ? const Icon(Icons.check) : Text('${f.count}'),
              onTap: () => Navigator.pop(ctx, f.name),
            ),
          if (folders.isEmpty)
            const ListTile(
              enabled: false,
              title: Text('아직 폴더가 없습니다. 노트 화면 메뉴의 ‘폴더로 이동’으로 만들 수 있어요.'),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    ref.read(homeFilterProvider.notifier).setFolder(picked.isEmpty ? null : picked);
  }

  Future<void> _newNote() async {
    final folder = ref.read(homeFilterProvider).folder;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: _BigChoice(
                icon: Icons.mic_rounded,
                title: '지금 녹음',
                subtitle: '실시간 받아쓰기와 요약',
                onTap: () => Navigator.pop(ctx, 'record'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _BigChoice(
                icon: Icons.upload_file_rounded,
                title: '파일 가져오기',
                subtitle: '음성 메모, 녹음 파일',
                onTap: () => Navigator.pop(ctx, 'import'),
              ),
            ),
          ]),
        ),
      ),
    );
    switch (choice) {
      case 'record':
        await _open(const RecordScreen());
      case 'import':
        await _open(ImportScreen(folder: folder));
    }
  }

  @override
  Widget build(BuildContext context) {
    final meetings = ref.watch(meetingsProvider);
    final filter = ref.watch(homeFilterProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(filter.folder ?? '노트'),
        actions: [
          IconButton(
            tooltip: '폴더',
            icon: Icon(filter.folder == null ? Icons.folder_outlined : Icons.folder),
            onPressed: _pickFolder,
          ),
          IconButton(
            tooltip: '설정',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const SettingsScreen()),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => ref.read(homeFilterProvider.notifier).setQuery(v),
              onChanged: (v) {
                if (v.isEmpty) ref.read(homeFilterProvider.notifier).setQuery('');
              },
              decoration: InputDecoration(
                hintText: '제목으로 검색',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: filter.query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          ref.read(homeFilterProvider.notifier).setQuery('');
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: categories.length + (filter.folder == null ? 0 : 1),
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                if (filter.folder != null && i == 0) {
                  return InputChip(
                    avatar: const Icon(Icons.folder, size: 16),
                    label: Text(filter.folder!),
                    onDeleted: () => ref.read(homeFilterProvider.notifier).setFolder(null),
                  );
                }
                final c = categories[i - (filter.folder == null ? 0 : 1)];
                final selected = filter.category == c;
                return ChoiceChip(
                  label: Text(c),
                  selected: selected,
                  showCheckmark: false,
                  selectedColor: scheme.primary,
                  labelStyle: TextStyle(
                    fontSize: 13,
                    color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  backgroundColor: scheme.surface,
                  onSelected: (_) => ref.read(homeFilterProvider.notifier).setCategory(c),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(meetingsProvider.future),
              child: meetings.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Icon(Icons.cloud_off, size: 48, color: scheme.outline),
                    const SizedBox(height: 12),
                    Text('서버에 연결하지 못했습니다.\n$e', textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text('설정에서 서버 주소와 토큰을 확인하세요.',
                        textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
                  ],
                ),
                data: (items) => items.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Icon(Icons.mic_none, size: 56, color: scheme.outline),
                        const SizedBox(height: 12),
                        Text(
                          filter.query.isEmpty && filter.category == '전체'
                              ? '아직 노트가 없습니다.\n아래 ‘새 노트’로 녹음하거나 파일을 가져오세요.'
                              : '조건에 맞는 노트가 없습니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ])
                    : _GroupedList(items: items, onTap: (m) => _open(MeetingScreen(meetingId: m.id))),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('새 노트'),
        onPressed: _newNote,
      ),
    );
  }
}

class _BigChoice extends StatelessWidget {
  const _BigChoice({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.6),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 36, color: scheme.primary),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _GroupedList extends StatelessWidget {
  const _GroupedList({required this.items, required this.onTap});

  final List<MeetingItem> items;
  final ValueChanged<MeetingItem> onTap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? lastHeader;
    for (final m in items) {
      final header = dateHeader(m.createdAt);
      if (header != lastHeader) {
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(20, rows.isEmpty ? 4 : 20, 20, 8),
          child: Text(header,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ));
        lastHeader = header;
      }
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: MeetingCard(meeting: m, onTap: () => onTap(m)),
      ));
    }
    rows.add(const SizedBox(height: 88));
    return ListView(children: rows);
  }
}

class MeetingCard extends StatelessWidget {
  const MeetingCard({super.key, required this.meeting, required this.onTap});

  final MeetingItem meeting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final template = NoteTemplate.of(m.template);
    final preview = m.oneLine ??
        (m.isRecording
            ? '녹음 중입니다.'
            : m.isActive
                ? '노트를 만드는 중입니다. 잠시 뒤 요약이 표시됩니다.'
                : m.isFailed
                    ? '처리에 실패했습니다. 열어서 다시 시도하세요.'
                    : '요약이 없습니다.');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                if (m.category != null) ...[
                  _Tag(text: m.category!, color: categoryColor(m.category, scheme)),
                  const SizedBox(width: 6),
                ],
                if (!m.isDone)
                  _Tag(
                    text: statusLabel(m.status),
                    color: m.isFailed ? scheme.error : (m.isRecording ? scheme.error : scheme.tertiary),
                    pulsing: m.isActive,
                  ),
                if (m.folder != null) ...[
                  const SizedBox(width: 6),
                  _Tag(text: m.folder!, color: scheme.secondary),
                ],
                const Spacer(),
                Text(timeOfDay(m.createdAt), style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
              ]),
              const SizedBox(height: 8),
              Text(m.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: m.oneLine == null ? scheme.outline : scheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 10),
              Row(children: [
                Icon(Icons.schedule, size: 14, color: scheme.outline),
                const SizedBox(width: 4),
                Text(m.durationSec == null ? '--:--' : formatClock(m.durationSec!),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                const SizedBox(width: 10),
                Icon(templateIcon(template.key), size: 14, color: scheme.outline),
                const SizedBox(width: 4),
                Text(template.label, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    m.keywords.take(3).map((k) => '#$k').join('  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color, this.pulsing = false});

  final String text;
  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (pulsing) ...[
          SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6, color: color)),
          const SizedBox(width: 5),
        ],
        Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
