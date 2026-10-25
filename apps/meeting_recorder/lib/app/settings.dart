import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Build-time defaults so a debug run on the emulator needs no typing:
/// `flutter run --dart-define=MEETING_API_TOKEN=... --dart-define=MEETING_API_URL=...`
const _defaultUrl = String.fromEnvironment(
  'MEETING_API_URL',
  defaultValue: 'http://10.0.2.2:8000',
);
const _defaultToken = String.fromEnvironment('MEETING_API_TOKEN');

class AppSettings {
  const AppSettings({
    required this.serverUrl,
    required this.token,
    required this.segmentSeconds,
    this.liveCaptions = true,
    this.defaultTemplate = 'meeting',
  });

  static const defaults = AppSettings(
    serverUrl: _defaultUrl,
    token: _defaultToken,
    segmentSeconds: 600,
  );

  final String serverUrl;
  final String token;
  final int segmentSeconds;

  /// 실시간 받아쓰기 default for new recordings (can be toggled per recording).
  final bool liveCaptions;
  final String defaultTemplate;

  /// ws(s):// base for the live captions socket.
  Uri liveUri(String meetingId, double offsetSec) {
    final base = Uri.parse(serverUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/meetings/$meetingId/live',
      queryParameters: {'offset': offsetSec.toStringAsFixed(2)},
    );
  }

  AppSettings copyWith({
    String? serverUrl,
    String? token,
    int? segmentSeconds,
    bool? liveCaptions,
    String? defaultTemplate,
  }) {
    return AppSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      segmentSeconds: segmentSeconds ?? this.segmentSeconds,
      liveCaptions: liveCaptions ?? this.liveCaptions,
      defaultTemplate: defaultTemplate ?? this.defaultTemplate,
    );
  }
}

class SettingsRepository {
  SettingsRepository([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _urlKey = 'server_url';
  static const _tokenKey = 'api_token';
  static const _segmentKey = 'segment_seconds';
  static const _liveKey = 'live_captions';
  static const _templateKey = 'default_template';

  Future<AppSettings> load() async {
    final url = await _storage.read(key: _urlKey);
    final token = await _storage.read(key: _tokenKey);
    final seg = int.tryParse(await _storage.read(key: _segmentKey) ?? '');
    final live = await _storage.read(key: _liveKey);
    final template = await _storage.read(key: _templateKey);
    return AppSettings(
      serverUrl: (url == null || url.isEmpty) ? AppSettings.defaults.serverUrl : url,
      token: (token == null || token.isEmpty) ? AppSettings.defaults.token : token,
      segmentSeconds: seg ?? AppSettings.defaults.segmentSeconds,
      liveCaptions: live == null ? AppSettings.defaults.liveCaptions : live == 'true',
      defaultTemplate: template ?? AppSettings.defaults.defaultTemplate,
    );
  }

  Future<void> save(AppSettings s) async {
    await _storage.write(key: _urlKey, value: s.serverUrl);
    await _storage.write(key: _tokenKey, value: s.token);
    await _storage.write(key: _segmentKey, value: s.segmentSeconds.toString());
    await _storage.write(key: _liveKey, value: s.liveCaptions.toString());
    await _storage.write(key: _templateKey, value: s.defaultTemplate);
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => SettingsRepository().load();

  Future<void> save(AppSettings s) async {
    await SettingsRepository().save(s);
    state = AsyncData(s);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
