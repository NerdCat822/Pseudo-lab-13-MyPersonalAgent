class Speaker {
  const Speaker({required this.id, required this.displayName, this.rawLabel});

  final String id;
  final String displayName;
  final String? rawLabel;

  factory Speaker.fromJson(Map<String, dynamic> j) => Speaker(
        id: j['id'] as String,
        displayName: j['display_name'] as String,
        rawLabel: j['raw_label'] as String?,
      );
}

class MeetingItem {
  const MeetingItem({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.status,
    this.durationSec,
    this.error,
    this.failedStep,
  });

  final String id;
  final String? title;
  final DateTime createdAt;
  final String status;
  final double? durationSec;
  final String? error;
  final String? failedStep;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isActive => !isDone && !isFailed;

  factory MeetingItem.fromJson(Map<String, dynamic> j) => MeetingItem(
        id: j['id'] as String,
        title: j['title'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        status: j['status'] as String,
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        error: j['error'] as String?,
        failedStep: j['failed_step'] as String?,
      );
}

class MeetingDetail extends MeetingItem {
  const MeetingDetail({
    required super.id,
    required super.title,
    required super.createdAt,
    required super.status,
    super.durationSec,
    super.error,
    super.failedStep,
    this.expectedSegments,
    required this.segmentsTotal,
    required this.segmentsReceived,
    required this.segmentsProcessing,
    required this.segmentsDone,
    required this.segmentsFailed,
    required this.costUsd,
    required this.hasSummary,
    required this.speakers,
  });

  final int? expectedSegments;
  final int segmentsTotal;
  final int segmentsReceived;
  final int segmentsProcessing;
  final int segmentsDone;
  final int segmentsFailed;
  final double costUsd;
  final bool hasSummary;
  final List<Speaker> speakers;

  /// Progress in 0..1 for the UI. Unknown total counts as "received so far".
  double get progress {
    final total = expectedSegments ?? segmentsTotal;
    if (total == 0) return 0;
    return (segmentsDone / total).clamp(0, 1);
  }

  factory MeetingDetail.fromJson(Map<String, dynamic> j) {
    final base = MeetingItem.fromJson(j);
    return MeetingDetail(
      id: base.id,
      title: base.title,
      createdAt: base.createdAt,
      status: base.status,
      durationSec: base.durationSec,
      error: base.error,
      failedStep: base.failedStep,
      expectedSegments: j['expected_segments'] as int?,
      segmentsTotal: j['segments_total'] as int,
      segmentsReceived: j['segments_received'] as int,
      segmentsProcessing: j['segments_processing'] as int,
      segmentsDone: j['segments_done'] as int,
      segmentsFailed: j['segments_failed'] as int,
      costUsd: (j['cost_usd'] as num).toDouble(),
      hasSummary: j['has_summary'] as bool,
      speakers: (j['speakers'] as List<dynamic>)
          .map((e) => Speaker.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Utterance {
  const Utterance({
    required this.id,
    required this.speakerId,
    required this.speakerName,
    required this.startSec,
    required this.endSec,
    required this.text,
  });

  final int id;
  final String? speakerId;
  final String speakerName;
  final double startSec;
  final double endSec;
  final String text;

  factory Utterance.fromJson(Map<String, dynamic> j) => Utterance(
        id: j['id'] as int,
        speakerId: j['speaker_id'] as String?,
        speakerName: j['speaker_name'] as String,
        startSec: (j['start_sec'] as num).toDouble(),
        endSec: (j['end_sec'] as num).toDouble(),
        text: j['text'] as String,
      );
}

class ActionItem {
  const ActionItem({required this.what, required this.who, required this.due});

  final String what;
  final String who;
  final String due;

  factory ActionItem.fromJson(Map<String, dynamic> j) => ActionItem(
        what: j['what'] as String? ?? '',
        who: j['who'] as String? ?? '',
        due: j['due'] as String? ?? '',
      );
}

class MeetingSummary {
  const MeetingSummary({
    required this.summary,
    required this.decisions,
    required this.actionItems,
    required this.topics,
    required this.openQuestions,
    required this.model,
  });

  final String summary;
  final List<String> decisions;
  final List<ActionItem> actionItems;
  final List<String> topics;
  final List<String> openQuestions;
  final String model;

  factory MeetingSummary.fromJson(Map<String, dynamic> j) => MeetingSummary(
        summary: j['summary'] as String? ?? '',
        decisions: _strings(j['decisions']),
        actionItems: (j['action_items'] as List<dynamic>? ?? const [])
            .map((e) => ActionItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        topics: _strings(j['topics']),
        openQuestions: _strings(j['open_questions']),
        model: j['model'] as String? ?? '',
      );

  static List<String> _strings(dynamic v) =>
      (v as List<dynamic>? ?? const []).map((e) => e.toString()).toList();
}

String formatClock(double sec) {
  final total = sec.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String statusLabel(String status) => switch (status) {
      'recording' => '녹음 중',
      'processing' => '전사 중',
      'merging' => '병합 중',
      'summarizing' => '요약 중',
      'done' => '완료',
      'failed' => '실패',
      _ => status,
    };
