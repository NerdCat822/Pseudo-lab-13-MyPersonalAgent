import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/api.dart';
import '../app/settings.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _segment = TextEditingController();
  String? _result;
  bool _loaded = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _segment.dispose();
    super.dispose();
  }

  AppSettings _current() => AppSettings(
        serverUrl: _url.text.trim(),
        token: _token.text.trim(),
        segmentSeconds: int.tryParse(_segment.text.trim()) ?? 600,
      );

  Future<void> _test() async {
    final s = _current();
    final api = MeetingApi(baseUrl: s.serverUrl, token: s.token);
    setState(() => _result = '확인 중…');
    try {
      await api.health();
      await api.listMeetings();
      setState(() => _result = '연결과 토큰 모두 정상입니다');
    } on ApiException catch (e) {
      setState(() => _result = '실패: ${e.message}');
    }
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).save(_current());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    if (!_loaded && settings.hasValue) {
      final s = settings.value!;
      _url.text = s.serverUrl;
      _token.text = s.token;
      _segment.text = s.segmentSeconds.toString();
      _loaded = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '서버 주소',
              helperText: '에뮬레이터: http://10.0.2.2:8000 · 실기기: Tailscale 주소',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '접근 토큰 (MEETING_API_TOKEN)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _segment,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '세그먼트 길이 (초)',
              helperText: '기본 600. 테스트할 때는 30~60으로 줄이면 빨리 볼 수 있습니다',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              OutlinedButton(onPressed: _test, child: const Text('연결 테스트')),
              const SizedBox(width: 12),
              Expanded(child: Text(_result ?? '')),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('저장')),
        ],
      ),
    );
  }
}
