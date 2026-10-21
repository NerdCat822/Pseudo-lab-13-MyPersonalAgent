import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/api.dart';
import '../app/models.dart';
import 'meeting/meeting_screen.dart';
import 'record/record_screen.dart';
import 'settings_screen.dart';

final meetingsProvider = FutureProvider.autoDispose<List<MeetingItem>>((ref) {
  return ref.watch(apiProvider).listMeetings();
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meetings = ref.watch(meetingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('회의 녹음'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
              ref.invalidate(meetingsProvider);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(meetingsProvider.future),
        child: meetings.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('서버에 연결하지 못했습니다.\n$e', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text('설정에서 서버 주소와 토큰을 확인하세요.', textAlign: TextAlign.center),
            ],
          ),
          data: (items) => items.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Center(child: Text('아직 회의가 없습니다. 아래 버튼으로 녹음을 시작하세요.')),
                  ],
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = items[i];
                    return ListTile(
                      title: Text(m.title ?? '제목 없음'),
                      subtitle: Text(
                        '${_fmtDate(m.createdAt)}'
                        '${m.durationSec != null ? ' · ${formatClock(m.durationSec!)}' : ''}',
                      ),
                      trailing: Chip(
                        label: Text(statusLabel(m.status)),
                        visualDensity: VisualDensity.compact,
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => MeetingScreen(meetingId: m.id)),
                        );
                        ref.invalidate(meetingsProvider);
                      },
                    );
                  },
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.mic),
        label: const Text('새 회의'),
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RecordScreen()),
          );
          ref.invalidate(meetingsProvider);
        },
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
