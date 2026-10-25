/// Note templates (에이닷 노트-style). Keys match the server.
class NoteTemplate {
  const NoteTemplate(this.key, this.label, this.description);

  final String key;
  final String label;
  final String description;

  static const all = <NoteTemplate>[
    NoteTemplate('meeting', '회의록', '안건별 논의, 결정사항, 할 일과 담당자'),
    NoteTemplate('keypoints', '요점 정리', '주제별 핵심과 자주 나온 단어'),
    NoteTemplate('lecture', '강의 노트', '목차별 정리와 핵심 개념, 복습 질문'),
    NoteTemplate('thoughts', '생각 노트', '내 아이디어와 할 일, AI 제안'),
  ];

  static NoteTemplate of(String? key) =>
      all.firstWhere((t) => t.key == key, orElse: () => all.first);
}

class Speaker {
  const Speaker({required this.id, required this.displayName, this.rawLabel, this.hasReference = false});

  final String id;
  final String displayName;
  final String? rawLabel;
  final bool hasReference;

  factory Speaker.fromJson(Map<String, dynamic> j) => Speaker(
        id: j['id'] as String,
        displayName: j['display_name'] as String,
        rawLabel: j['raw_label'] as String?,
        hasReference: j['reference_clip_path'] != null,
      );
}

List<String> _stringList(dynamic v) =>
    (v as List<dynamic>? ?? const []).map((e) => e.toString()).toList();

class MeetingItem {
  const MeetingItem({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.status,
    this.durationSec,
    this.error,
    this.failedStep,
    this.template = 'meeting',
    this.folder,
    this.oneLine,
    this.category,
    this.keywords = const [],
  });

  final String id;
  final String? title;
  final DateTime createdAt;
  final String status;
  final double? durationSec;
  final String? error;
  final String? failedStep;
  final String template;
  final String? folder;

  /// Preview fields from the summary (null until the meeting is summarized).
  final String? oneLine;
  final String? category;
  final List<String> keywords;

  String get displayTitle => (title == null || title!.isEmpty) ? '제목 없는 노트' : title!;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isRecording => status == 'recording';
  bool get isActive => !isDone && !isFailed;

  factory MeetingItem.fromJson(Map<String, dynamic> j) => MeetingItem(
        id: j['id'] as String,
        title: j['title'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        status: j['status'] as String,
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        error: j['error'] as String?,
        failedStep: j['failed_step'] as String?,
        template: j['template'] as String? ?? 'meeting',
        folder: j['folder'] as String?,
        oneLine: j['one_line'] as String?,
        category: j['category'] as String?,
        keywords: _stringList(j['keywords']),
      );
}

class SegmentBrief {
  const SegmentBrief({
    required this.id,
    required this.index,
    required this.startOffsetSec,
    required this.durationSec,
    required this.status,
  });

  final String id;
  final int index;
  final double startOffsetSec;
  final double? durationSec;
  final String status;

  factory SegmentBrief.fromJson(Map<String, dynamic> j) => SegmentBrief(
        id: j['id'] as String,
        index: j['index'] as int,
        startOffsetSec: (j['start_offset_sec'] as num).toDouble(),
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        status: j['status'] as String,
      );
}

class Bookmark {
  const Bookmark({required this.id, required this.atSec, this.note});

  final int id;
  final double atSec;
  final String? note;

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        id: j['id'] as int,
        atSec: (j['at_sec'] as num).toDouble(),
        note: j['note'] as String?,
      );
}

/// '실시간 요약': bullets for one time window of the live captions.
class LiveSummaryItem {
  const LiveSummaryItem({required this.id, required this.startSec, required this.endSec, required this.bullets});

  final int id;
  final double startSec;
  final double endSec;
  final List<String> bullets;

  String get text => bullets.join('\n');

  factory LiveSummaryItem.fromJson(Map<String, dynamic> j) => LiveSummaryItem(
        id: j['id'] as int,
        startSec: (j['start_sec'] as num).toDouble(),
        endSec: (j['end_sec'] as num).toDouble(),
        bullets: j['bullets'] != null
            ? _stringList(j['bullets'])
            : (j['text'] as String? ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList(),
      );
}

class LiveCaption {
  const LiveCaption({required this.id, required this.atSec, required this.text});

  final int id;
  final double atSec;
  final String text;

  factory LiveCaption.fromJson(Map<String, dynamic> j) => LiveCaption(
        id: j['id'] as int,
        atSec: (j['at_sec'] as num).toDouble(),
        text: j['text'] as String,
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
    super.template,
    super.folder,
    super.oneLine,
    super.category,
    super.keywords,
    this.expectedSegments,
    required this.segmentsTotal,
    required this.segmentsReceived,
    required this.segmentsProcessing,
    required this.segmentsDone,
    required this.segmentsFailed,
    required this.costUsd,
    required this.hasSummary,
    required this.speakers,
    this.segments = const [],
    this.bookmarks = const [],
    this.liveSummaries = const [],
    this.liveCaptionCount = 0,
    this.chatCount = 0,
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
  final List<SegmentBrief> segments;
  final List<Bookmark> bookmarks;
  final List<LiveSummaryItem> liveSummaries;
  final int liveCaptionCount;
  final int chatCount;

  /// Segment that contains an absolute meeting time, for playback.
  SegmentBrief? segmentAt(double sec) {
    SegmentBrief? best;
    for (final s in segments) {
      if (s.startOffsetSec <= sec && (best == null || s.startOffsetSec > best.startOffsetSec)) {
        best = s;
      }
    }
    return best;
  }

  /// Progress in 0..1 for the UI. Unknown total counts as "received so far".
  double get progress {
    final total = expectedSegments ?? segmentsTotal;
    if (total == 0) return 0;
    return (segmentsDone / total).clamp(0, 1);
  }

  factory MeetingDetail.fromJson(Map<String, dynamic> j) {
    final base = MeetingItem.fromJson(j);
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        (j[key] as List<dynamic>? ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();
    return MeetingDetail(
      id: base.id,
      title: base.title,
      createdAt: base.createdAt,
      status: base.status,
      durationSec: base.durationSec,
      error: base.error,
      failedStep: base.failedStep,
      template: base.template,
      folder: base.folder,
      oneLine: base.oneLine,
      category: base.category,
      keywords: base.keywords,
      expectedSegments: j['expected_segments'] as int?,
      segmentsTotal: j['segments_total'] as int,
      segmentsReceived: j['segments_received'] as int,
      segmentsProcessing: j['segments_processing'] as int? ?? 0,
      segmentsDone: j['segments_done'] as int,
      segmentsFailed: j['segments_failed'] as int,
      costUsd: (j['cost_usd'] as num).toDouble(),
      hasSummary: j['has_summary'] as bool,
      speakers: list('speakers', Speaker.fromJson),
      segments: list('segments', SegmentBrief.fromJson),
      bookmarks: list('bookmarks', Bookmark.fromJson),
      liveSummaries: list('live_summaries', LiveSummaryItem.fromJson),
      liveCaptionCount: j['live_caption_count'] as int? ?? 0,
      chatCount: j['chat_count'] as int? ?? 0,
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

  Map<String, dynamic> toJson() => {'what': what, 'who': who, 'due': due};

  factory ActionItem.fromJson(Map<String, dynamic> j) => ActionItem(
        what: j['what'] as String? ?? '',
        who: j['who'] as String? ?? '',
        due: j['due'] as String? ?? '',
      );
}

class NoteSection {
  const NoteSection({required this.heading, required this.bullets});

  final String heading;
  final List<String> bullets;

  Map<String, dynamic> toJson() => {'heading': heading, 'bullets': bullets};

  factory NoteSection.fromJson(Map<String, dynamic> j) =>
      NoteSection(heading: j['heading'] as String? ?? '', bullets: _stringList(j['bullets']));
}

class KeyTerm {
  const KeyTerm({required this.term, required this.explanation});

  final String term;
  final String explanation;

  Map<String, dynamic> toJson() => {'term': term, 'explanation': explanation};

  factory KeyTerm.fromJson(Map<String, dynamic> j) =>
      KeyTerm(term: j['term'] as String? ?? '', explanation: j['explanation'] as String? ?? '');
}

class KeywordCount {
  const KeywordCount(this.word, this.count);

  final String word;
  final int count;

  factory KeywordCount.fromJson(Map<String, dynamic> j) =>
      KeywordCount(j['word'] as String? ?? '', (j['count'] as num?)?.toInt() ?? 0);
}

class MeetingSummary {
  const MeetingSummary({
    required this.template,
    required this.title,
    required this.oneLine,
    required this.summary,
    required this.sections,
    required this.keyPoints,
    required this.decisions,
    required this.actionItems,
    required this.topics,
    required this.openQuestions,
    required this.keyTerms,
    required this.suggestions,
    required this.keywordCounts,
    required this.category,
    required this.model,
    required this.edited,
  });

  final String template;
  final String title;
  final String oneLine;
  final String summary;
  final List<NoteSection> sections;
  final List<String> keyPoints;
  final List<String> decisions;
  final List<ActionItem> actionItems;
  final List<String> topics;
  final List<String> openQuestions;
  final List<KeyTerm> keyTerms;
  final List<String> suggestions;
  final List<KeywordCount> keywordCounts;
  final String? category;
  final String model;
  final bool edited;

  bool get isEmpty => summary.isEmpty && keyPoints.isEmpty && oneLine.isEmpty && sections.isEmpty;

  factory MeetingSummary.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        (j[key] as List<dynamic>? ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();
    return MeetingSummary(
      template: j['template'] as String? ?? 'meeting',
      title: j['title'] as String? ?? '',
      oneLine: j['one_line'] as String? ?? '',
      summary: j['summary'] as String? ?? '',
      sections: list('sections', NoteSection.fromJson),
      keyPoints: _stringList(j['key_points']),
      decisions: _stringList(j['decisions']),
      actionItems: list('action_items', ActionItem.fromJson),
      topics: _stringList(j['topics']),
      openQuestions: _stringList(j['open_questions']),
      keyTerms: list('key_terms', KeyTerm.fromJson),
      suggestions: _stringList(j['suggestions']),
      keywordCounts: list('keyword_counts', KeywordCount.fromJson),
      category: j['category'] as String?,
      model: j['model'] as String? ?? '',
      edited: j['edited'] as bool? ?? false,
    );
  }
}

class ChatSource {
  const ChatSource({required this.kind, this.atSec, this.speaker, this.text, this.title, this.url});

  final String kind; // transcript | web
  final double? atSec;
  final String? speaker;
  final String? text;
  final String? title;
  final String? url;

  bool get isWeb => kind == 'web';

  factory ChatSource.fromJson(Map<String, dynamic> j) => ChatSource(
        kind: j['kind'] as String? ?? 'transcript',
        atSec: (j['at_sec'] as num?)?.toDouble(),
        speaker: j['speaker'] as String?,
        text: j['text'] as String?,
        title: j['title'] as String?,
        url: j['url'] as String?,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.webSearch,
    required this.sources,
    required this.createdAt,
  });

  final int id;
  final String role;
  final String content;
  final bool webSearch;
  final List<ChatSource> sources;
  final DateTime createdAt;

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as int,
        role: j['role'] as String,
        content: j['content'] as String,
        webSearch: j['web_search'] as bool? ?? false,
        sources: (j['sources'] as List<dynamic>? ?? const [])
            .map((e) => ChatSource.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

class FolderInfo {
  const FolderInfo(this.name, this.count);

  final String name;
  final int count;

  factory FolderInfo.fromJson(Map<String, dynamic> j) =>
      FolderInfo(j['name'] as String, (j['count'] as num).toInt());
}

String formatClock(double sec) {
  final total = sec.isFinite && sec > 0 ? sec.floor() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String statusLabel(String status) => switch (status) {
      'recording' => '녹음 중',
      'processing' => '받아쓰는 중',
      'merging' => '정리 중',
      'summarizing' => '요약 중',
      'done' => '완료',
      'failed' => '실패',
      _ => status,
    };

/// "오늘", "어제", or "10월 21일 (화)" for list section headers.
String dateHeader(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final diff = DateTime(n.year, n.month, n.day).difference(day).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '어제';
  const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  final year = d.year == n.year ? '' : '${d.year}년 ';
  return '$year${d.month}월 ${d.day}일 (${weekdays[d.weekday - 1]})';
}

String timeOfDay(DateTime d) {
  final h = d.hour;
  final period = h < 12 ? '오전' : '오후';
  final hour12 = h % 12 == 0 ? 12 : h % 12;
  return '$period $hour12:${d.minute.toString().padLeft(2, '0')}';
}
