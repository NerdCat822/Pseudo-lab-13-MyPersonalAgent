import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/api.dart';
import '../../app/models.dart';

const _suggestions = [
  '핵심만 세 줄로 정리해 줘',
  '누가 무엇을 언제까지 하기로 했어?',
  '결정된 사항만 알려 줘',
  '낯선 용어를 설명해 줘',
];

/// "AI에게 질문하기" for one note. Works while recording too (the server answers from the
/// live captions so far). Tapping a [mm:ss] citation calls [onJump].
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.meetingId, this.onJump, this.recording = false});

  final String meetingId;
  final ValueChanged<double>? onJump;
  final bool recording;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  bool _web = false;
  String? _pending;
  bool _pendingWeb = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await ref.read(apiProvider).chat(widget.meetingId);
      if (mounted) setState(() => _messages = m);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
      _toBottom();
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? text]) async {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || _sending) return;
    final web = _web || q.contains('웹') || q.contains('용어');
    setState(() {
      _sending = true;
      _pending = q;
      _pendingWeb = web;
      _error = null;
    });
    _input.clear();
    _toBottom();
    try {
      await ref.read(apiProvider).ask(widget.meetingId, q, webSearch: web);
      final m = await ref.read(apiProvider).chat(widget.meetingId);
      if (mounted) setState(() => _messages = m);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
        _input.text = q;
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _pending = null;
        });
      }
      _toBottom();
    }
  }

  Future<void> _clear() async {
    await ref.read(apiProvider).clearChat(widget.meetingId);
    if (mounted) setState(() => _messages = const []);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    if (_messages.isEmpty && _pending == null && !_loading) {
      items.add(_Intro(recording: widget.recording, onPick: _send));
    }
    for (final m in _messages) {
      items.add(m.isUser
          ? _UserBubble(text: m.content, web: m.webSearch)
          : _AnswerBubble(message: m, onJump: widget.onJump));
    }
    if (_pending != null) {
      items.add(_UserBubble(text: _pending!, web: _pendingWeb));
      items.add(const _Thinking());
    }
    if (_error != null) {
      items.add(Padding(
        padding: const EdgeInsets.all(8),
        child: Text(_error!, style: TextStyle(color: scheme.error)),
      ));
    }
    return Column(
      children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  children: items,
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('웹'),
                  avatar: const Icon(Icons.travel_explore, size: 16),
                  selected: _web,
                  showCheckmark: false,
                  tooltip: '노트에 없는 용어나 사실은 웹에서 찾아 답합니다',
                  onSelected: (v) => setState(() => _web = v),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: '노트에 대해 물어보세요', isDense: true),
                  ),
                ),
                IconButton.filled(
                  onPressed: _sending ? null : () => _send(),
                  icon: const Icon(Icons.arrow_upward),
                ),
                if (_messages.isNotEmpty)
                  IconButton(
                    tooltip: '대화 지우기',
                    onPressed: _sending ? null : _clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.recording, required this.onPick});

  final bool recording;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Icon(Icons.auto_awesome, color: scheme.primary, size: 32),
          const SizedBox(height: 8),
          Text(
            recording ? '녹음 중에도 지금까지의 내용을 물어볼 수 있어요' : '이 노트에 대해 무엇이든 물어보세요',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text('답의 [00:00] 시각을 누르면 그 부분을 들을 수 있어요',
              style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [for (final s in _suggestions) ActionChip(label: Text(s), onPressed: () => onPick(s))],
          ),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.web});

  final String text;
  final bool web;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (web) ...[
              Icon(Icons.travel_explore, size: 14, color: scheme.onPrimary.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
            ],
            Flexible(child: Text(text, style: TextStyle(color: scheme.onPrimary, height: 1.4))),
          ],
        ),
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('노트를 읽고 답을 찾는 중…', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

final _token = RegExp(
  r'\[(\d{1,3}):(\d{2})(?::(\d{2}))?\]|\(?\[([^\]]+)\]\((https?://[^)\s]+)\)\)?|\*\*([^*]+)\*\*',
);

/// Answer text with tappable [mm:ss] citations, markdown links and **bold**.
class AnswerText extends StatelessWidget {
  const AnswerText({super.key, required this.text, this.onJump});

  final String text;
  final ValueChanged<double>? onJump;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
        final c = m.group(3) == null ? null : int.parse(m.group(3)!);
        final sec = (c == null ? a * 60 + b : a * 3600 + b * 60 + c).toDouble();
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onJump == null ? null : () => onJump!(sec),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (onJump != null) Icon(Icons.play_arrow_rounded, size: 13, color: scheme.primary),
                Text(formatClock(sec), style: TextStyle(fontSize: 12, color: scheme.primary)),
              ]),
            ),
          ),
        ));
      } else if (m.group(5) != null) {
        final url = m.group(5)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: InkWell(
            onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            child: Text(m.group(4)!,
                style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline)),
          ),
        ));
      } else if (m.group(6) != null) {
        spans.add(TextSpan(text: m.group(6), style: const TextStyle(fontWeight: FontWeight.w700)));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(children: spans), style: const TextStyle(height: 1.5));
  }
}

class _AnswerBubble extends StatelessWidget {
  const _AnswerBubble({required this.message, this.onJump});

  final ChatMessage message;
  final ValueChanged<double>? onJump;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // [mm:ss] citations are tappable inline; list transcript sources only when the answer has
    // none inline (e.g. the model cited in another format).
    final inline = RegExp(r'\[\d{1,3}:\d{2}').hasMatch(message.content);
    final transcript = inline ? const <ChatSource>[] : message.sources.where((s) => !s.isWeb).take(3).toList();
    final web = message.sources.where((s) => s.isWeb).toList();
    return Padding(
      padding: const EdgeInsets.only(right: 24, bottom: 10),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: message.content));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('답변을 복사했습니다')));
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text('AI', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary, fontSize: 12)),
                ]),
                const SizedBox(height: 6),
                AnswerText(text: message.content, onJump: onJump),
                if (transcript.isNotEmpty || web.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in transcript)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.play_circle_outline, size: 16),
                          label: Text('${formatClock(s.atSec ?? 0)} ${s.speaker ?? ''}'),
                          tooltip: s.text,
                          onPressed: onJump == null || s.atSec == null ? null : () => onJump!(s.atSec!),
                        ),
                      for (final s in web)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.link, size: 16),
                          label: Text(Uri.tryParse(s.url ?? '')?.host ?? (s.title ?? '웹')),
                          tooltip: s.title,
                          onPressed: s.url == null
                              ? null
                              : () => launchUrl(Uri.parse(s.url!), mode: LaunchMode.externalApplication),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet wrapper, e.g. for asking during a recording.
Future<void> showChatSheet(BuildContext context, String meetingId, {bool recording = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(children: [
                Text('AI에게 질문', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ),
            Expanded(child: ChatView(meetingId: meetingId, recording: recording)),
          ],
        ),
      ),
    ),
  );
}
