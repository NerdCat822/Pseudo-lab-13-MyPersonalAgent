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
  });

  static const defaults = AppSettings(
    serverUrl: _defaultUrl,
    token: _defaultToken,
    segmentSeconds: 600,
  );

  final String serverUrl;
  final String token;
  final int segmentSeconds;

  AppSettings copyWith({String? serverUrl, String? token, int? segmentSeconds}) {
    return AppSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      segmentSeconds: segmentSeconds ?? this.segmentSeconds,
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

  Future<AppSettings> load() async {
    final url = await _storage.read(key: _urlKey);
    final token = await _storage.read(key: _tokenKey);
    final seg = int.tryParse(await _storage.read(key: _segmentKey) ?? '');
    return AppSettings(
      serverUrl: (url == null || url.isEmpty) ? AppSettings.defaults.serverUrl : url,
      token: (token == null || token.isEmpty) ? AppSettings.defaults.token : token,
      segmentSeconds: seg ?? AppSettings.defaults.segmentSeconds,
    );
  }

  Future<void> save(AppSettings s) async {
    await _storage.write(key: _urlKey, value: s.serverUrl);
    await _storage.write(key: _tokenKey, value: s.token);
    await _storage.write(key: _segmentKey, value: s.segmentSeconds.toString());
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
