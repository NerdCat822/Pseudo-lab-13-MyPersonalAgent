import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meeting_recorder/features/record/wav_writer.dart';

Uint8List pcm(int samples, int value) {
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(i * 2, value, Endian.little);
  }
  return b.buffer.asUint8List();
}

int u32(List<int> bytes, int at) => ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(at, Endian.little);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wav_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('segments rotate exactly on the byte boundary, gapless, with valid headers', () {
    // 1 s segments at 8 kHz = 16000 bytes; feed 2.5 s in uneven chunks.
    final w = WavSegmentWriter(directory: dir.path, sampleRate: 8000, segmentSeconds: 1)..open();
    final closed = <ClosedSegment>[];
    for (final n in [3000, 7000, 9000, 1000]) {
      closed.addAll(w.add(pcm(n, 100)));
    }
    expect(w.elapsedSec, closeTo(20000 / 8000, 1e-9));
    final last = w.close();
    closed.add(last!);
    expect(closed.map((c) => c.index), [0, 1, 2]);
    expect(closed.map((c) => c.startSec), [0.0, 1.0, 2.0]);
    expect(closed.map((c) => c.durationSec), [1.0, 1.0, 0.5]);
    for (final c in closed) {
      final bytes = c.file.readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      final data = (c.durationSec * 16000).round();
      expect(u32(bytes, 4), 36 + data);
      expect(u32(bytes, 40), data);
      expect(u32(bytes, 24), 8000);
      expect(bytes.length, 44 + data);
    }
  });

  test('closing right after a rotation leaves no empty file', () {
    final w = WavSegmentWriter(directory: dir.path, sampleRate: 8000, segmentSeconds: 1)..open();
    expect(w.add(pcm(8000, 1)).length, 1);
    expect(w.close(), isNull);
    expect(dir.listSync().whereType<File>().map((f) => f.path.split('/').last), ['000.wav']);
  });

  test('level, downsampling and silence helpers', () {
    expect(pcmLevel(pcm(100, 0)), 0);
    expect(pcmLevel(pcm(100, 32767)), closeTo(1.0, 0.01));
    expect(pcmLevel(pcm(100, 33)), closeTo(0.0, 0.01)); // about -60 dBFS
    final down = downsample2(Uint8List.fromList([0x10, 0, 0x20, 0, 0x30, 0, 0x50, 0]));
    expect(ByteData.sublistView(down).getInt16(0, Endian.little), 0x18);
    expect(ByteData.sublistView(down).getInt16(2, Endian.little), 0x40);
    expect(silencePcm(24000, 0.5).length, 24000);
  });
}
