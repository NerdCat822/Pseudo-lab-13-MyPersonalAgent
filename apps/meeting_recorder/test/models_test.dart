import 'package:flutter_test/flutter_test.dart';
import 'package:meeting_recorder/app/models.dart';

void main() {
  test('MeetingDetail parses server JSON and computes progress', () {
    final d = MeetingDetail.fromJson({
      'id': 'abc',
      'title': null,
      'created_at': '2026-10-21T02:00:00Z',
      'duration_sec': 61.5,
      'status': 'processing',
      'error': null,
      'failed_step': null,
      'expected_segments': 4,
      'segments_total': 3,
      'segments_received': 1,
      'segments_processing': 1,
      'segments_done': 1,
      'segments_failed': 0,
      'cost_usd': 0.012,
      'has_summary': false,
      'speakers': [
        {'id': 's1', 'raw_label': 'A', 'display_name': 'A', 'reference_clip_path': null},
      ],
    });
    expect(d.isActive, isTrue);
    expect(d.progress, closeTo(0.25, 1e-9));
    expect(d.speakers.single.displayName, 'A');
    expect(statusLabel(d.status), '전사 중');
  });

  test('MeetingSummary tolerates missing lists', () {
    final s = MeetingSummary.fromJson({'summary': '짧음', 'model': 'x'});
    expect(s.decisions, isEmpty);
    expect(s.actionItems, isEmpty);
  });

  test('formatClock', () {
    expect(formatClock(0), '00:00');
    expect(formatClock(65.9), '01:05');
    expect(formatClock(3725), '1:02:05');
  });
}
