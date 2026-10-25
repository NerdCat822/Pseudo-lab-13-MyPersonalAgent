import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'settings.dart';

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

typedef Progress = void Function(int sent, int total);

class MeetingApi {
  MeetingApi({required String baseUrl, required String token})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(minutes: 10),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );

  final Dio _dio;

  /// AI answers (and web search) can take a while.
  static final _slow = Options(receiveTimeout: const Duration(seconds: 120));

  Future<T> _call<T>(Future<Response<dynamic>> Function() fn, T Function(dynamic) parse) async {
    try {
      final r = await fn();
      return parse(r.data);
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['detail'] is Map) {
        final d = data['detail'] as Map;
        throw ApiException(
          d['code']?.toString() ?? 'error',
          d['message']?.toString() ?? e.message ?? 'error',
          statusCode: e.response?.statusCode,
        );
      }
      throw ApiException(
        e.type.name,
        e.message ?? '서버에 연결할 수 없습니다',
        statusCode: e.response?.statusCode,
      );
    }
  }

  Map<String, dynamic> _map(dynamic d) => d as Map<String, dynamic>;
  List<T> _list<T>(dynamic d, T Function(Map<String, dynamic>) f) =>
      (d as List<dynamic>).map((e) => f(e as Map<String, dynamic>)).toList();

  Future<bool> health() => _call(() => _dio.get('/health'), (d) => d['status'] == 'ok');

  Future<List<MeetingItem>> listMeetings({String? query, String? category, String? folder}) =>
      _call(
        () => _dio.get('/meetings',
            queryParameters: {'q': ?query, 'category': ?category, 'folder': ?folder}),
        (d) => _list(d, MeetingItem.fromJson),
      );

  Future<List<FolderInfo>> folders() =>
      _call(() => _dio.get('/folders'), (d) => _list(d, FolderInfo.fromJson));

  Future<MeetingDetail> createMeeting({String? title, String? template, String? folder}) => _call(
        () => _dio.post('/meetings', data: {'title': title, 'template': template, 'folder': folder}),
        (d) => MeetingDetail.fromJson(_map(d)),
      );

  Future<void> deleteMeeting(String id) => _call(() => _dio.delete('/meetings/$id'), (_) {});

  Future<MeetingDetail> getMeeting(String id) =>
      _call(() => _dio.get('/meetings/$id'), (d) => MeetingDetail.fromJson(_map(d)));

  /// Rename and/or move to a folder. Pass [clearFolder] to remove it from its folder.
  Future<MeetingDetail> patchMeeting(String id, {String? title, String? folder, bool clearFolder = false}) =>
      _call(
        () => _dio.patch('/meetings/$id', data: {
          'title': ?title,
          if (folder != null || clearFolder) 'folder': folder,
        }),
        (d) => MeetingDetail.fromJson(_map(d)),
      );

  Future<void> uploadSegment({
    required String meetingId,
    required int index,
    required double startOffsetSec,
    required double? durationSec,
    required File file,
    String? filename,
    Progress? onProgress,
  }) =>
      _call(
        () async => _dio.post(
          '/meetings/$meetingId/segments',
          data: FormData.fromMap({
            'index': index,
            'start_offset_sec': startOffsetSec,
            'duration_sec': ?durationSec,
            'file': await MultipartFile.fromFile(file.path,
                filename: filename ?? file.uri.pathSegments.last),
          }),
          onSendProgress: onProgress,
        ),
        (_) {},
      );

  Future<MeetingDetail> finish(String id, {required int segmentCount, double? durationSec}) =>
      _call(
        () => _dio.post('/meetings/$id/finish', data: {
          'segment_count': segmentCount,
          'duration_sec': ?durationSec,
        }),
        (d) => MeetingDetail.fromJson(_map(d)),
      );

  Future<List<Utterance>> transcript(String id) => _call(
        () => _dio.get('/meetings/$id/transcript'),
        (d) => _list(d['utterances'], Utterance.fromJson),
      );

  Future<Utterance> editUtterance(String meetingId, int utteranceId, String text) => _call(
        () => _dio.patch('/meetings/$meetingId/utterances/$utteranceId', data: {'text': text}),
        (d) => Utterance.fromJson(_map(d)),
      );

  Future<List<LiveCaption>> liveCaptions(String id) =>
      _call(() => _dio.get('/meetings/$id/live-captions'), (d) => _list(d, LiveCaption.fromJson));

  Future<void> editLiveSummary(String meetingId, int summaryId, String text) => _call(
        () => _dio.patch('/meetings/$meetingId/live-summaries/$summaryId', data: {'text': text}),
        (_) {},
      );

  Future<MeetingSummary> summary(String id) =>
      _call(() => _dio.get('/meetings/$id/summary'), (d) => MeetingSummary.fromJson(_map(d)));

  /// Hand edits to the note; only the keys present in [fields] change.
  Future<MeetingSummary> editSummary(String id, Map<String, dynamic> fields) => _call(
        () => _dio.put('/meetings/$id/summary', data: fields),
        (d) => MeetingSummary.fromJson(_map(d)),
      );

  Future<Speaker> renameSpeaker(String meetingId, String speakerId, String name) => _call(
        () => _dio.patch('/meetings/$meetingId/speakers/$speakerId', data: {'display_name': name}),
        (d) => Speaker.fromJson(_map(d)),
      );

  Future<MeetingDetail> retry(String id) =>
      _call(() => _dio.post('/meetings/$id/retry'), (d) => MeetingDetail.fromJson(_map(d)));

  Future<MeetingDetail> resummarize(String id, {String? template}) => _call(
        () => _dio.post('/meetings/$id/resummarize', data: {'template': ?template}),
        (d) => MeetingDetail.fromJson(_map(d)),
      );

  Future<Bookmark> addBookmark(String meetingId, double atSec, {String? note}) => _call(
        () => _dio.post('/meetings/$meetingId/bookmarks', data: {'at_sec': atSec, 'note': ?note}),
        (d) => Bookmark.fromJson(_map(d)),
      );

  Future<void> deleteBookmark(String meetingId, int bookmarkId) =>
      _call(() => _dio.delete('/meetings/$meetingId/bookmarks/$bookmarkId'), (_) {});

  Future<List<ChatMessage>> chat(String meetingId) =>
      _call(() => _dio.get('/meetings/$meetingId/chat'), (d) => _list(d, ChatMessage.fromJson));

  Future<ChatMessage> ask(String meetingId, String question, {bool webSearch = false}) => _call(
        () => _dio.post('/meetings/$meetingId/chat',
            data: {'question': question, 'web_search': webSearch}, options: _slow),
        (d) => ChatMessage.fromJson(_map(d)),
      );

  Future<void> clearChat(String meetingId) =>
      _call(() => _dio.delete('/meetings/$meetingId/chat'), (_) {});

  Future<File> _download(String path, File dest) async {
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.part');
    try {
      await _dio.download(path, tmp.path, options: Options(receiveTimeout: const Duration(minutes: 5)));
      await tmp.rename(dest.path);
      return dest;
    } on DioException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      final data = e.response?.data;
      throw ApiException(
        e.type.name,
        data is Map && data['detail'] is Map ? '${data['detail']['message']}' : (e.message ?? '파일을 받지 못했습니다'),
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// Downloads one segment's audio to [dest] (cached; skipped when it already exists).
  Future<File> downloadSegmentAudio(String meetingId, String segmentId, File dest) async {
    if (await dest.exists() && await dest.length() > 0) return dest;
    return _download('/meetings/$meetingId/segments/$segmentId/audio', dest);
  }

  /// The whole recording as one MP3, for 녹음 파일 공유.
  Future<File> downloadMeetingAudio(String meetingId, File dest) =>
      _download('/meetings/$meetingId/audio', dest);
}

final apiProvider = Provider<MeetingApi>((ref) {
  final s = ref.watch(settingsProvider).value ?? AppSettings.defaults;
  return MeetingApi(baseUrl: s.serverUrl, token: s.token);
});
