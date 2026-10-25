import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app/models.dart';

/// What to include when sharing (선택 공유).
class ExportParts {
  const ExportParts({this.note = true, this.liveSummaries = true, this.transcript = false});

  final bool note;
  final bool liveSummaries;
  final bool transcript;
}

class NoteExportData {
  const NoteExportData({
    required this.detail,
    required this.summary,
    required this.utterances,
    required this.captions,
  });

  final MeetingDetail detail;
  final MeetingSummary? summary;
  final List<Utterance> utterances;
  final List<LiveCaption> captions;

  String get metaLine {
    final d = detail;
    return [
      '${dateHeader(d.createdAt)} ${timeOfDay(d.createdAt)}',
      if (d.durationSec != null) formatClock(d.durationSec!),
      NoteTemplate.of(summary?.template ?? d.template).label,
      if (d.speakers.isNotEmpty) '참석: ${d.speakers.map((e) => e.displayName).join(', ')}',
    ].join(' · ');
  }
}

String exportMarkdown(NoteExportData data, ExportParts parts) {
  final d = data.detail;
  final s = data.summary;
  final b = StringBuffer('# ${d.displayTitle}\n\n${data.metaLine}\n\n');
  void list(String title, List<String> items, {String bullet = '-'}) {
    if (items.isEmpty) return;
    b.writeln('## $title\n');
    for (final i in items) {
      b.writeln('$bullet $i');
    }
    b.writeln();
  }

  if (parts.note && s != null && !s.isEmpty) {
    if (s.oneLine.isNotEmpty) b.writeln('> ${s.oneLine}\n');
    for (final sec in s.sections) {
      list(sec.heading, sec.bullets);
    }
    list('주요 내용', s.keyPoints);
    if (s.summary.isNotEmpty && s.summary != s.oneLine) b.writeln('## 상세 요약\n\n${s.summary}\n');
    list('결정사항', s.decisions);
    if (s.actionItems.isNotEmpty) {
      b.writeln('## 할 일\n');
      for (final a in s.actionItems) {
        final meta = [if (a.who.isNotEmpty) a.who, if (a.due.isNotEmpty) a.due].join(', ');
        b.writeln('- [ ] ${a.what}${meta.isEmpty ? '' : ' ($meta)'}');
      }
      b.writeln();
    }
    if (s.keyTerms.isNotEmpty) {
      list('핵심 용어', [for (final t in s.keyTerms) '**${t.term}**: ${t.explanation}']);
    }
    list('AI 제안', s.suggestions);
    list(s.template == 'lecture' ? '복습 질문' : '미해결 질문', s.openQuestions);
    if (s.topics.isNotEmpty) b.writeln('${s.topics.map((e) => '#${e.replaceAll(' ', '_')}').join(' ')}\n');
  }
  if (parts.liveSummaries && d.liveSummaries.isNotEmpty) {
    b.writeln('## 실시간 요약\n');
    for (final w in d.liveSummaries) {
      b.writeln('**${formatClock(w.startSec)}–${formatClock(w.endSec)}**');
      for (final x in w.bullets) {
        b.writeln('- $x');
      }
      b.writeln();
    }
  }
  if (parts.transcript) {
    b.writeln('## 받아쓰기\n');
    if (data.utterances.isNotEmpty) {
      for (final u in data.utterances) {
        b.writeln('[${formatClock(u.startSec)}] **${u.speakerName}**: ${u.text}');
      }
    } else {
      for (final c in data.captions) {
        b.writeln('[${formatClock(c.atSec)}] ${c.text}');
      }
    }
  }
  return b.toString().trimRight();
}

/// A4 PDF of the note. Noto Sans KR is fetched from Google Fonts on first use (cached by
/// `printing`), so Korean renders without bundling a font in the app.
Future<Uint8List> exportPdf(NoteExportData data, ExportParts parts) async {
  final regular = await PdfGoogleFonts.notoSansKRRegular();
  final bold = await PdfGoogleFonts.notoSansKRBold();
  final theme = pw.ThemeData.withFont(base: regular, bold: bold);
  final accent = PdfColor.fromHex('#6C4DFF');
  final grey = PdfColor.fromHex('#6B6B76');
  final d = data.detail;
  final s = data.summary;

  pw.Widget h2(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(t, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: accent)),
      );
  pw.Widget bullets(List<String> items) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final i in items)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('•  '),
                pw.Expanded(child: pw.Text(i, style: const pw.TextStyle(lineSpacing: 2))),
              ]),
            ),
        ],
      );

  final body = <pw.Widget>[
    pw.Text(d.displayTitle, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    pw.Text(data.metaLine, style: pw.TextStyle(fontSize: 9, color: grey)),
  ];
  if (parts.note && s != null && !s.isEmpty) {
    if (s.oneLine.isNotEmpty) {
      body.add(pw.Container(
        margin: const pw.EdgeInsets.only(top: 12),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(color: PdfColor.fromHex('#EEE9FF'), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Text(s.oneLine, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      ));
    }
    for (final sec in s.sections) {
      body
        ..add(h2(sec.heading))
        ..add(bullets(sec.bullets));
    }
    if (s.keyPoints.isNotEmpty) body..add(h2('주요 내용'))..add(bullets(s.keyPoints));
    if (s.summary.isNotEmpty && s.summary != s.oneLine) {
      body..add(h2('상세 요약'))..add(pw.Text(s.summary, style: const pw.TextStyle(lineSpacing: 2)));
    }
    if (s.decisions.isNotEmpty) body..add(h2('결정사항'))..add(bullets(s.decisions));
    if (s.actionItems.isNotEmpty) {
      body
        ..add(h2('할 일'))
        ..add(bullets([
          for (final a in s.actionItems)
            '${a.what}${[if (a.who.isNotEmpty) a.who, if (a.due.isNotEmpty) a.due].isEmpty ? '' : ' (${[if (a.who.isNotEmpty) a.who, if (a.due.isNotEmpty) a.due].join(', ')})'}',
        ]));
    }
    if (s.keyTerms.isNotEmpty) {
      body..add(h2('핵심 용어'))..add(bullets([for (final t in s.keyTerms) '${t.term}: ${t.explanation}']));
    }
    if (s.suggestions.isNotEmpty) body..add(h2('AI 제안'))..add(bullets(s.suggestions));
    if (s.openQuestions.isNotEmpty) {
      body..add(h2(s.template == 'lecture' ? '복습 질문' : '미해결 질문'))..add(bullets(s.openQuestions));
    }
  }
  if (parts.liveSummaries && d.liveSummaries.isNotEmpty) {
    body.add(h2('실시간 요약'));
    for (final w in d.liveSummaries) {
      body
        ..add(pw.Text('${formatClock(w.startSec)} – ${formatClock(w.endSec)}', style: pw.TextStyle(fontSize: 9, color: grey)))
        ..add(bullets(w.bullets));
    }
  }
  if (parts.transcript) {
    body.add(h2('받아쓰기'));
    final lines = data.utterances.isNotEmpty
        ? [for (final u in data.utterances) ('${formatClock(u.startSec)}  ${u.speakerName}', u.text)]
        : [for (final c in data.captions) (formatClock(c.atSec), c.text)];
    for (final (who, text) in lines) {
      body.add(pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 92, child: pw.Text(who, style: pw.TextStyle(fontSize: 9, color: grey))),
          pw.Expanded(child: pw.Text(text, style: const pw.TextStyle(fontSize: 10, lineSpacing: 2))),
        ]),
      ));
    }
  }

  final doc = pw.Document(title: d.displayTitle, author: 'meeting_recorder');
  doc.addPage(pw.MultiPage(
    theme: theme,
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 48),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 8, color: grey)),
    ),
    build: (_) => body,
  ));
  return doc.save();
}
