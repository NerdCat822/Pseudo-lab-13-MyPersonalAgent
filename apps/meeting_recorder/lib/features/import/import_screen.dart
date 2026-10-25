import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/api.dart';
import '../../app/models.dart';
import '../../app/settings.dart';
import '../../app/theme.dart';
import '../meeting/meeting_screen.dart';

/// 음성 파일 가져오기: an existing recording (e.g. iPhone 음성 메모) becomes a note.
/// The server normalizes it, cuts long files into chunks and keeps speakers consistent.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, this.folder});

  final String? folder;

  static const extensions = ['m4a', 'mp3', 'wav', 'flac', 'aac', 'ogg', 'opus', 'mp4', 'webm', 'amr', '3gp', 'caf'];

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final _title = TextEditingController();
  PlatformFile? _file;
  int? _size;
  late String _template = (ref.read(settingsProvider).value ?? AppSettings.defaults).defaultTemplate;
  double? _progress;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      // FileType.audio (audio/*) rather than custom extensions: Android maps .m4a to
      // audio/mpeg in the extension filter, which greys out real audio/mp4 files such as
      // voice memos. The extension is checked here instead.
      final f = await FilePicker.pickFile(type: FileType.audio, dialogTitle: '가져올 음성 파일');
      if (f == null) return;
      final ext = (f.extension ?? '').toLowerCase();
      if (!ImportScreen.extensions.contains(ext)) {
        setState(() => _error = '지원하지 않는 형식입니다 (.$ext). ${ImportScreen.extensions.join(', ')} 파일을 골라 주세요.');
        return;
      }
      final size = f.lengthSync() ?? await f.length();
      setState(() {
        _file = f;
        _size = size;
        _error = null;
        final dot = f.name.lastIndexOf('.');
        _title.text = dot > 0 ? f.name.substring(0, dot) : f.name;
      });
    } catch (e) {
      setState(() => _error = '파일을 열지 못했습니다: $e');
    }
  }

  Future<File> _localCopy(PlatformFile f) async {
    final path = f.path;
    if (path != null && await File(path).exists()) return File(path);
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/import/${f.name}');
    await out.parent.create(recursive: true);
    final sink = out.openWrite();
    await sink.addStream(f.readAsByteStream());
    await sink.close();
    return out;
  }

  Future<void> _import() async {
    final f = _file;
    if (f == null || _busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    final api = ref.read(apiProvider);
    try {
      final local = await _localCopy(f);
      final title = _title.text.trim();
      final meeting = await api.createMeeting(
        title: title.isEmpty ? null : title,
        template: _template,
        folder: widget.folder,
      );
      await api.uploadSegment(
        meetingId: meeting.id,
        index: 0,
        startOffsetSec: 0,
        durationSec: null,
        file: local,
        filename: f.name,
        onProgress: (sent, total) {
          if (total > 0 && mounted) setState(() => _progress = sent / total);
        },
      );
      await api.finish(meeting.id, segmentCount: 1);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => MeetingScreen(meetingId: meeting.id)),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _mb(int? bytes) => bytes == null ? '' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('음성 파일 가져오기')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(Icons.audio_file_outlined, color: scheme.primary, size: 32),
                title: Text(_file?.name ?? '파일을 고르세요'),
                subtitle: Text(_file == null
                    ? 'm4a, mp3, wav, flac 등 · 아이폰 음성 메모도 됩니다'
                    : '${_mb(_size)}${widget.folder != null ? ' · 폴더 ${widget.folder}' : ''}'),
                trailing: TextButton(onPressed: _busy ? null : _pick, child: Text(_file == null ? '고르기' : '바꾸기')),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              enabled: !_busy,
              decoration: const InputDecoration(hintText: '제목 (비워 두면 AI가 지어 줍니다)', prefixIcon: Icon(Icons.edit_outlined)),
            ),
            const SizedBox(height: 16),
            Text('템플릿', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _template,
              onChanged: (v) {
                if (!_busy && v != null) setState(() => _template = v);
              },
              child: Column(children: [
                for (final t in NoteTemplate.all)
                  RadioListTile<String>(
                    value: t.key,
                    secondary: Icon(templateIcon(t.key)),
                    title: Text(t.label),
                    subtitle: Text(t.description),
                    contentPadding: EdgeInsets.zero,
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            if (_progress != null && _busy) ...[
              LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 6),
              Text(_progress! < 1 ? '올리는 중 ${(100 * _progress!).round()}%' : '서버에 맡기는 중…',
                  textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            FilledButton.icon(
              onPressed: _file == null || _busy ? null : _import,
              icon: const Icon(Icons.upload),
              label: const Text('노트 만들기'),
            ),
            const SizedBox(height: 8),
            Text('긴 파일은 서버가 10분 단위로 나눠 받아쓰고, 화자를 끝까지 이어 붙입니다.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}
