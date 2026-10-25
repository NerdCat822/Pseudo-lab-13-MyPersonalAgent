import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/api.dart';
import 'note_export.dart';

/// 선택 공유: pick the parts (note / live summaries / transcript), then text, PDF or audio.
Future<void> showShareSheet(BuildContext context, MeetingApi api, NoteExportData data) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ShareSheet(api: api, data: data),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.api, required this.data});

  final MeetingApi api;
  final NoteExportData data;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _note = true;
  late bool _live = widget.data.detail.liveSummaries.isNotEmpty;
  bool _transcript = false;
  String? _busy;

  ExportParts get _parts => ExportParts(note: _note, liveSummaries: _live, transcript: _transcript);

  String get _fileBase => widget.data.detail.displayTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  Future<void> _run(String label, Future<void> Function() job) async {
    setState(() => _busy = label);
    try {
      await job();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label 실패: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data.detail;
    final hasTranscript = widget.data.utterances.isNotEmpty || widget.data.captions.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('공유할 내용', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          CheckboxListTile(
            value: _note,
            onChanged: widget.data.summary == null ? null : (v) => setState(() => _note = v ?? false),
            title: const Text('노트 (템플릿 정리)'),
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            value: _live,
            onChanged: d.liveSummaries.isEmpty ? null : (v) => setState(() => _live = v ?? false),
            title: Text('실시간 요약${d.liveSummaries.isEmpty ? ' (없음)' : ''}'),
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            value: _transcript,
            onChanged: hasTranscript ? (v) => setState(() => _transcript = v ?? false) : null,
            title: const Text('받아쓰기 전체'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          if (_busy != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('$_busy 준비 중…'),
              ]),
            )
          else ...[
            FilledButton.icon(
              icon: const Icon(Icons.share),
              label: const Text('텍스트로 공유'),
              onPressed: () => _run('텍스트', () async {
                await SharePlus.instance.share(ShareParams(
                  text: exportMarkdown(widget.data, _parts),
                  subject: d.displayTitle,
                ));
              }),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF로 공유'),
              onPressed: () => _run('PDF', () async {
                final bytes = await exportPdf(widget.data, _parts);
                await Printing.sharePdf(bytes: bytes, filename: '$_fileBase.pdf');
              }),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('텍스트 복사'),
              onPressed: () => _run('복사', () async {
                await Clipboard.setData(ClipboardData(text: exportMarkdown(widget.data, _parts)));
              }),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.audio_file_outlined),
              label: const Text('녹음 파일 공유 (MP3)'),
              onPressed: d.segments.isEmpty
                  ? null
                  : () => _run('녹음 파일', () async {
                        final dir = await getTemporaryDirectory();
                        final file = await widget.api
                            .downloadMeetingAudio(d.id, File('${dir.path}/share/$_fileBase.mp3'));
                        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: d.displayTitle));
                      }),
            ),
          ],
        ],
      ),
    );
  }
}
