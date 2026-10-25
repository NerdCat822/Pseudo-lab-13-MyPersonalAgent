import 'package:flutter_test/flutter_test.dart';
import 'package:meeting_recorder/app/models.dart';
import 'package:meeting_recorder/app/settings.dart';
import 'package:meeting_recorder/features/meeting/note_export.dart';

Map<String, dynamic> detailJson() => {
      'id': 'abc',
      'title': null,
      'created_at': '2026-10-21T02:00:00Z',
      'duration_sec': 61.5,
      'status': 'processing',
      'error': null,
      'failed_step': null,
      'expected_segments': 4,
      'template': 'lecture',
      'folder': '수업',
      'one_line': '한 줄',
      'category': '학습',
      'keywords': ['a', 'b'],
      'segments_total': 3,
      'segments_received': 1,
      'segments_processing': 1,
      'segments_done': 1,
      'segments_failed': 0,
      'cost_usd': 0.012,
      'has_summary': false,
      'speakers': [
        {'id': 's1', 'raw_label': 'A', 'display_name': '참석자 1', 'reference_clip_path': '/x.wav'},
      ],
      'segments': [
        {'id': 'g0', 'index': 0, 'start_offset_sec': 0, 'duration_sec': 600, 'status': 'done'},
        {'id': 'g1', 'index': 1, 'start_offset_sec': 600.5, 'duration_sec': 300, 'status': 'done'},
      ],
      'bookmarks': [
        {'id': 1, 'at_sec': 12.5, 'note': null},
      ],
      'live_summaries': [
        {'id': 7, 'start_sec': 0, 'end_sec': 120, 'text': '첫째\n둘째'},
      ],
      'live_caption_count': 9,
      'chat_count': 2,
    };

void main() {
  test('MeetingDetail parses template, folder, segments, live summaries', () {
    final d = MeetingDetail.fromJson(detailJson());
    expect(d.isActive, isTrue);
    expect(d.displayTitle, '제목 없는 노트');
    expect(d.template, 'lecture');
    expect(NoteTemplate.of(d.template).label, '강의 노트');
    expect(d.folder, '수업');
    expect(d.progress, closeTo(0.25, 1e-9));
    expect(d.speakers.single.hasReference, isTrue);
    expect(d.segmentAt(5)!.id, 'g0');
    expect(d.segmentAt(700)!.id, 'g1');
    expect(d.liveSummaries.single.bullets, ['첫째', '둘째']);
    expect(d.liveCaptionCount, 9);
    expect(statusLabel(d.status), '받아쓰는 중');
  });

  test('MeetingItem tolerates old servers (no preview, template, folder)', () {
    final m = MeetingItem.fromJson({'id': 'x', 'title': 'T', 'created_at': '2026-10-21T02:00:00Z', 'status': 'done'});
    expect(m.oneLine, isNull);
    expect(m.keywords, isEmpty);
    expect(m.template, 'meeting');
    expect(m.folder, isNull);
  });

  test('MeetingSummary v3 and v1 shapes', () {
    final v3 = MeetingSummary.fromJson({
      'template': 'keypoints',
      'title': '제목',
      'one_line': '한 줄',
      'summary': '상세',
      'sections': [
        {'heading': '주제', 'bullets': ['a', 'b']},
      ],
      'key_points': ['p1'],
      'decisions': ['d1'],
      'action_items': [
        {'what': '할 일', 'who': '참석자 2', 'due': '금요일'},
      ],
      'topics': ['FTS5'],
      'open_questions': [],
      'key_terms': [
        {'term': 'FTS5', 'explanation': '전문 검색'},
      ],
      'suggestions': [],
      'keyword_counts': [
        {'word': 'FTS5', 'count': 3},
      ],
      'edited': true,
      'model': 'x',
    });
    expect(v3.sections.single.bullets, ['a', 'b']);
    expect(v3.keyTerms.single.term, 'FTS5');
    expect(v3.keywordCounts.single.count, 3);
    expect(v3.edited, isTrue);
    final v1 = MeetingSummary.fromJson({'summary': '짧음', 'model': 'x'});
    expect(v1.template, 'meeting');
    expect(v1.sections, isEmpty);
  });

  test('ChatMessage parses transcript and web sources', () {
    final m = ChatMessage.fromJson({
      'id': 3,
      'role': 'assistant',
      'content': '금요일입니다 [00:12].',
      'web_search': true,
      'created_at': '2026-10-25T06:00:00Z',
      'sources': [
        {'kind': 'transcript', 'at_sec': 12.1, 'speaker': '참석자 1', 'text': '…'},
        {'kind': 'web', 'title': 'SQLite', 'url': 'https://www.sqlite.org/fts5.html'},
      ],
    });
    expect(m.isUser, isFalse);
    expect(m.sources.where((s) => s.isWeb).single.url, contains('sqlite.org'));
  });

  test('markdown export honours the selected parts', () {
    final d = MeetingDetail.fromJson(detailJson());
    final s = MeetingSummary.fromJson({
      'template': 'meeting',
      'one_line': '한 줄 요약',
      'summary': '상세',
      'decisions': ['결정 하나'],
      'action_items': [
        {'what': '할 일 하나', 'who': '참석자 1', 'due': '수요일'},
      ],
      'model': 'x',
    });
    final data = NoteExportData(
      detail: d,
      summary: s,
      utterances: const [
        Utterance(id: 1, speakerId: 's1', speakerName: '참석자 1', startSec: 3, endSec: 4, text: '안녕하세요'),
      ],
      captions: const [],
    );
    final full = exportMarkdown(data, const ExportParts(note: true, liveSummaries: true, transcript: true));
    expect(full, contains('> 한 줄 요약'));
    expect(full, contains('- [ ] 할 일 하나 (참석자 1, 수요일)'));
    expect(full, contains('## 실시간 요약'));
    expect(full, contains('[00:03] **참석자 1**: 안녕하세요'));
    final noteOnly = exportMarkdown(data, const ExportParts(note: true, liveSummaries: false, transcript: false));
    expect(noteOnly, isNot(contains('받아쓰기')));
    expect(noteOnly, isNot(contains('실시간 요약')));
  });

  test('live socket URI swaps the scheme and keeps the offset', () {
    const s = AppSettings(serverUrl: 'http://10.0.2.2:8000', token: 't', segmentSeconds: 600);
    expect(s.liveUri('m1', 12.345).toString(), 'ws://10.0.2.2:8000/meetings/m1/live?offset=12.35');
    const secure = AppSettings(serverUrl: 'https://box.tail.ts.net/', token: 't', segmentSeconds: 600);
    expect(secure.liveUri('m1', 0).toString(), 'wss://box.tail.ts.net/meetings/m1/live?offset=0.00');
  });

  test('formatClock, dateHeader, timeOfDay', () {
    expect(formatClock(0), '00:00');
    expect(formatClock(65.9), '01:05');
    expect(formatClock(3725), '1:02:05');
    final now = DateTime(2026, 10, 24, 15, 0);
    expect(dateHeader(DateTime(2026, 10, 24, 9), now: now), '오늘');
    expect(dateHeader(DateTime(2026, 10, 23, 23), now: now), '어제');
    expect(dateHeader(DateTime(2026, 10, 21, 11), now: now), '10월 21일 (수)');
    expect(timeOfDay(DateTime(2026, 1, 1, 13, 7)), '오후 1:07');
  });
}
