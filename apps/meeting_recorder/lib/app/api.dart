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
  String toString() => '$code: $message';
}

class MeetingApi {
  MeetingApi({required String baseUrl, required String token})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(minutes: 5),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );

  final Dio _dio;

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

  Future<bool> health() => _call(() => _dio.get('/health'), (d) => d['status'] == 'ok');

  Future<List<MeetingItem>> listMeetings({String? query}) => _call(
        () => _dio.get('/meetings', queryParameters: {'q': ?query}),
        (d) => (d as List<dynamic>)
            .map((e) => MeetingItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<MeetingDetail> createMeeting(String? title) => _call(
        () => _dio.post('/meetings', data: {'title': title}),
        (d) => MeetingDetail.fromJson(d as Map<String, dynamic>),
      );

  Future<MeetingDetail> getMeeting(String id) => _call(
        () => _dio.get('/meetings/$id'),
        (d) => MeetingDetail.fromJson(d as Map<String, dynamic>),
      );

  Future<void> uploadSegment({
    required String meetingId,
    required int index,
    required double startOffsetSec,
    required double? durationSec,
    required File file,
  }) =>
      _call(
        () async => _dio.post(
          '/meetings/$meetingId/segments',
          data: FormData.fromMap({
            'index': index,
            'start_offset_sec': startOffsetSec,
            'duration_sec': ?durationSec,
            'file': await MultipartFile.fromFile(file.path, filename: file.uri.pathSegments.last),
          }),
        ),
        (_) {},
      );

  Future<MeetingDetail> finish(String id, {required int segmentCount, double? durationSec}) =>
      _call(
        () => _dio.post('/meetings/$id/finish', data: {
          'segment_count': segmentCount,
          'duration_sec': ?durationSec,
        }),
        (d) => MeetingDetail.fromJson(d as Map<String, dynamic>),
      );

  Future<List<Utterance>> transcript(String id) => _call(
        () => _dio.get('/meetings/$id/transcript'),
        (d) => (d['utterances'] as List<dynamic>)
            .map((e) => Utterance.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<MeetingSummary> summary(String id) => _call(
        () => _dio.get('/meetings/$id/summary'),
        (d) => MeetingSummary.fromJson(d as Map<String, dynamic>),
      );

  Future<Speaker> renameSpeaker(String meetingId, String speakerId, String name) => _call(
        () => _dio.patch('/meetings/$meetingId/speakers/$speakerId', data: {'display_name': name}),
        (d) => Speaker.fromJson(d as Map<String, dynamic>),
      );

  Future<MeetingDetail> retry(String id) => _call(
        () => _dio.post('/meetings/$id/retry'),
        (d) => MeetingDetail.fromJson(d as Map<String, dynamic>),
      );
}

final apiProvider = Provider<MeetingApi>((ref) {
  final s = ref.watch(settingsProvider).value ?? AppSettings.defaults;
  return MeetingApi(baseUrl: s.serverUrl, token: s.token);
});
