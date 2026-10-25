import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class ClosedSegment {
  const ClosedSegment({
    required this.index,
    required this.file,
    required this.startSec,
    required this.durationSec,
  });

  final int index;
  final File file;
  final double startSec;
  final double durationSec;
}

/// Writes 16-bit mono PCM into consecutive WAV files of exactly [segmentSeconds] each.
///
/// Rotation happens on a byte boundary inside the incoming stream, so consecutive segments
/// are gapless and their start offsets are exact (unlike stopping and restarting a recorder).
class WavSegmentWriter {
  WavSegmentWriter({required this.directory, required this.sampleRate, required int segmentSeconds})
      : segmentBytes = math.max(1, segmentSeconds) * sampleRate * 2;

  final String directory;
  final int sampleRate;
  final int segmentBytes;

  RandomAccessFile? _raf;
  File? _file;
  int _index = 0;
  int _data = 0;
  int _before = 0;

  int get bytesPerSec => sampleRate * 2;
  int get index => _index;
  bool get isOpen => _raf != null;
  double get elapsedSec => (_before + _data) / bytesPerSec;

  String _path(int index) => '$directory/${index.toString().padLeft(3, '0')}.wav';

  void open() {
    _file = File(_path(_index));
    _raf = _file!.openSync(mode: FileMode.write);
    _raf!.writeFromSync(header(0, sampleRate));
    _data = 0;
  }

  /// Appends PCM; returns the segments that were completed by this chunk.
  List<ClosedSegment> add(Uint8List pcm) {
    final closed = <ClosedSegment>[];
    if (_raf == null) open();
    var offset = 0;
    final length = pcm.length - pcm.length % 2;
    while (offset < length) {
      final room = segmentBytes - _data;
      final take = math.min(room, length - offset);
      _raf!.writeFromSync(pcm, offset, offset + take);
      _data += take;
      offset += take;
      if (_data >= segmentBytes) {
        closed.add(_closeCurrent());
        _index++;
        open();
      }
    }
    return closed;
  }

  ClosedSegment _closeCurrent() {
    final raf = _raf!;
    raf.setPositionSync(4);
    raf.writeFromSync(_u32(36 + _data));
    raf.setPositionSync(40);
    raf.writeFromSync(_u32(_data));
    raf.closeSync();
    final segment = ClosedSegment(
      index: _index,
      file: _file!,
      startSec: _before / bytesPerSec,
      durationSec: _data / bytesPerSec,
    );
    _before += _data;
    _raf = null;
    return segment;
  }

  /// Finishes the open file. An empty trailing file (stop right after a rotation) is deleted.
  ClosedSegment? close() {
    if (_raf == null) return null;
    if (_data == 0) {
      _raf!.closeSync();
      _raf = null;
      _file?.deleteSync();
      return null;
    }
    return _closeCurrent();
  }

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

  static Uint8List header(int dataBytes, int sampleRate) {
    final b = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // PCM chunk size
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    b.setUint16(32, 2, Endian.little); // block align
    b.setUint16(34, 16, Endian.little); // bits
    tag(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }
}

/// 0..1 input level of a PCM16 chunk (-60 dBFS .. 0 dBFS).
double pcmLevel(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) return 0;
  final data = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = data.getInt16(i * 2, Endian.little);
    sum += s * s;
  }
  final rms = math.sqrt(sum / n);
  if (rms < 1) return 0;
  final db = 20 * math.log(rms / 32768) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

/// 48 kHz -> 24 kHz by averaging sample pairs (fallback when the device refuses 24 kHz).
Uint8List downsample2(Uint8List pcm) {
  final n = pcm.length ~/ 4;
  final input = ByteData.sublistView(pcm);
  final out = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final a = input.getInt16(i * 4, Endian.little);
    final b = input.getInt16(i * 4 + 2, Endian.little);
    out.setInt16(i * 2, (a + b) ~/ 2, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Short silence, used so that a recording stopped instantly still yields one segment.
Uint8List silencePcm(int sampleRate, double seconds) => Uint8List((sampleRate * seconds).round() * 2);
