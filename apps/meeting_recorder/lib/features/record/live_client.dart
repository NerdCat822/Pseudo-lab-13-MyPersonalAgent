import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

enum LiveStatus { off, connecting, ready, reconnecting, failed }

/// One caption line in the live view. Partial lines grow until they turn final.
class LiveLine {
  LiveLine({required this.id, required this.atSec, required this.text, this.isFinal = false});

  final String id;
  double atSec;
  String text;
  bool isFinal;
}

/// Client for the server's live captions socket (`WS /meetings/{id}/live`).
///
/// Audio goes out as binary PCM16 frames; JSON events come back. The connection is best
/// effort: when it drops, it reconnects with the current recording offset; if the server
/// keeps refusing, it gives up and the recording itself carries on untouched.
class LiveClient {
  LiveClient({
    required this.uriFor,
    required this.token,
    required this.onEvent,
    required this.onStatus,
  });

  /// Builds the socket URI; called on every (re)connect so the offset is current.
  final Uri Function() uriFor;
  final String token;
  final void Function(Map<String, dynamic> event) onEvent;
  final void Function(LiveStatus status, String? message) onStatus;

  WebSocket? _ws;
  bool _stopping = false;
  bool _disposed = false;
  bool _fatal = false;
  int _failures = 0;
  Timer? _retry;
  Completer<void>? _closed;

  static const _fatalCodes = {4401, 4404, 4409, 4503};
  static const _maxFailures = 6;

  Future<void> start() async {
    _stopping = false;
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed || _stopping || _fatal) return;
    onStatus(_failures == 0 ? LiveStatus.connecting : LiveStatus.reconnecting, null);
    try {
      final ws = await WebSocket.connect(
        uriFor().toString(),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (_disposed || _stopping) {
        await ws.close();
        return;
      }
      _ws = ws;
      ws.listen(
        (data) {
          if (data is String) _handle(data);
        },
        onDone: () => _onDone(ws),
        onError: (_) => _onDone(ws),
        cancelOnError: true,
      );
    } catch (e) {
      _scheduleRetry('$e');
    }
  }

  void _handle(String raw) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (event['type']) {
      case 'status':
        if (event['state'] == 'ready') {
          _failures = 0;
          onStatus(LiveStatus.ready, null);
        } else {
          onStatus(LiveStatus.reconnecting, null);
        }
      case 'closed':
        _closed?.complete();
      case 'error':
        final code = event['code'] as String? ?? '';
        if (code == 'meeting_not_recording' || code == 'ai_unavailable' || code == 'not_found') {
          _fatal = true;
          onStatus(LiveStatus.failed, event['message'] as String? ?? code);
        }
    }
    onEvent(event);
  }

  void _onDone(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    final closed = _closed;
    if (closed != null && !closed.isCompleted) closed.complete();
    if (_stopping || _disposed) return;
    if (_fatalCodes.contains(ws.closeCode)) {
      _fatal = true;
      onStatus(LiveStatus.failed, '실시간 받아쓰기를 쓸 수 없습니다 (${ws.closeCode})');
      return;
    }
    _scheduleRetry(ws.closeReason);
  }

  void _scheduleRetry(String? reason) {
    if (_disposed || _stopping || _fatal) return;
    _failures++;
    if (_failures > _maxFailures) {
      onStatus(LiveStatus.failed, '실시간 받아쓰기 연결에 실패했습니다. 녹음은 계속됩니다.');
      return;
    }
    onStatus(LiveStatus.reconnecting, reason);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: math.min(10, 2 * _failures)), _connect);
  }

  void send(Uint8List pcm) {
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(pcm);
  }

  /// Ask the server to finish the last turn, wait briefly for the final captions, close.
  Future<void> stop() async {
    _stopping = true;
    _retry?.cancel();
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) {
      final closed = Completer<void>();
      _closed = closed;
      ws.add(jsonEncode({'type': 'stop'}));
      await closed.future.timeout(const Duration(seconds: 10), onTimeout: () {});
      await ws.close();
    }
    _ws = null;
    onStatus(LiveStatus.off, null);
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    _ws = null;
  }
}
