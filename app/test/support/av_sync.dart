/// Measuring sound against picture in an encoded file, shared by the heavy
/// sync tests (`integration_video_start_offset_test.dart`,
/// `integration_output_conformance_test.dart`): white frames by luma, beeps
/// or clicks by onset, both on the file's own timestamps; an AVI's stored
/// video and audio headers; packet timing.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'worker_harness.dart';

/// Width x height of the first video stream.
Future<int> _pictureSize(String path) async {
  final s = await WorkerHarness.firstStream(path, selector: 'v:0', entries: ['width', 'height']);
  return int.parse('${s!['width']}') * int.parse('${s['height']}');
}

/// Presentation times, on the file's own timeline, of its white frames and of
/// the onsets of its beeps (loud after 5 ms of quiet; the first 5 ms never
/// count, since a copied track can start inside a beep).
Future<({List<double> flashes, List<double> beeps, double videoStart})> events(
    String path) async {
  final vf = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
    '-of', 'json', path,
  ]);
  final pts = [
    for (final f in vf['frames'] as List) double.parse('${f['pts_time']}'),
  ];
  final luma = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'quiet', '-i', path, '-map', '0:v:0', '-fps_mode', 'passthrough',
     '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  final y = luma.stdout as List<int>;
  final n = await _pictureSize(path);
  final flashes = <double>[];
  for (var i = 0; (i + 1) * n <= y.length && i < pts.length; i++) {
    var sum = 0;
    for (var k = i * n; k < (i + 1) * n; k += 97) {
      sum += y[k];
    }
    if (sum / (n / 97).ceil() > 200) flashes.add(pts[i]);
  }

  final beeps = await beepOnsets(path);
  return (flashes: flashes, beeps: beeps, videoStart: pts.isEmpty ? double.nan : pts.first);
}

/// The onsets of the first audio stream's beeps on the file's own timeline
/// (loud after 5 ms of quiet; the first 5 ms never count, since a copied
/// track can start inside a beep). Needs no video timestamps, so it also
/// reads a source whose pictures have none (task #58's source lags).
Future<List<double>> beepOnsets(String path) async {
  final af = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-show_entries',
    'frame=pts_time,nb_samples:stream=sample_rate', '-of', 'json', path,
  ]);
  final rate = int.parse('${(af['streams'] as List).first['sample_rate']}');
  final pcm = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'quiet', '-i', path, '-map', '0:a:0', '-ac', '1', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  final bytes = Uint8List.fromList(pcm.stdout as List<int>);
  final samples = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
  final quiet = rate ~/ 200;
  final beeps = <double>[];
  var pos = 0;
  var last = -10.0;
  for (final f in af['frames'] as List) {
    final count = int.parse('${f['nb_samples']}');
    final t0 = double.parse('${f['pts_time']}');
    for (var k = 0; k < count; k++) {
      final i = pos + k;
      if (i < quiet || i >= samples.length || samples[i].abs() <= 0.3) continue;
      var loudBefore = false;
      for (var j = i - quiet; j < i; j++) {
        if (samples[j].abs() > 0.3) {
          loudBefore = true;
          break;
        }
      }
      if (loudBefore) continue;
      final t = t0 + k / rate;
      if (t - last > 0.5) beeps.add(t);
      last = t;
    }
    pos += count;
  }
  return beeps;
}

/// Each white frame has its beep: the first beep from 0.5 s before it to 1.5 s
/// after (beeps are 2 s apart and the fault was late sound), within half a frame.
Future<void> expectInSync(String what, String path,
    {required int flashes, double tolerance = 0.5 / 25}) async {
  final e = await events(path);
  expect(e.flashes, hasLength(flashes), reason: '$what: white frames at ${e.flashes}');
  for (final f in e.flashes) {
    final near = e.beeps.where((b) => b - f >= -0.5 && b - f <= 1.5).toList();
    expect(near, isNotEmpty, reason: '$what: no beep for the flash at $f (beeps ${e.beeps})');
    expect((near.first - f).abs(), lessThan(tolerance),
        reason: '$what: the beep is ${(near.first - f).toStringAsFixed(4)} s from '
            'the flash at $f');
  }
}

/// Each audio stream's header in an AVI, as written: `wFormatTag`, channels,
/// `nBlockAlign`, and `dwSuggestedBufferSize` (avienc's trailer puts the
/// stream's largest chunk there). Walks the RIFF lists, as the worker does.
Future<List<({int tag, int channels, int blockAlign, int largest})>> aviAudioHeaders(
    String path) async {
  final raf = await File(path).open();
  final data = await raf.read(1 << 16);
  await raf.close();
  final b = ByteData.sublistView(data);
  String fourcc(int at) => String.fromCharCodes(data.sublist(at, at + 4));
  Iterable<(String, int, int)> chunks(int start, int end) sync* {
    var i = start;
    while (i + 8 <= end) {
      final size = b.getUint32(i + 4, Endian.little);
      yield (fourcc(i), i + 8, size);
      i += 8 + size + (size & 1);
    }
  }

  final out = <({int tag, int channels, int blockAlign, int largest})>[];
  for (final (c, o, s) in chunks(12, data.length)) {
    if (c != 'LIST' || fourcc(o) != 'hdrl') continue;
    for (final (c2, o2, s2) in chunks(o + 4, o + s)) {
      if (c2 != 'LIST' || fourcc(o2) != 'strl') continue;
      int? strh, strf;
      for (final (c3, o3, _) in chunks(o2 + 4, o2 + s2)) {
        if (c3 == 'strh') strh = o3;
        if (c3 == 'strf') strf = o3;
      }
      if (strh == null || strf == null || fourcc(strh) != 'auds') continue;
      out.add((
        tag: b.getUint16(strf, Endian.little),
        channels: b.getUint16(strf + 2, Endian.little),
        blockAlign: b.getUint16(strf + 12, Endian.little),
        largest: b.getUint32(strh + 36, Endian.little),
      ));
    }
  }
  return out;
}

/// The first audio stream's packets as ffmpeg's AVI demuxer reads them: their
/// sizes and timestamps (in the stream's time base, one AAC packet per tick).
Future<({List<int> sizes, List<int> pts})> audioPackets(String path) async {
  final a = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'packet=pts,size',
    '-of', 'json', path,
  ]);
  final packets = a['packets'] as List;
  return (
    sizes: [for (final pk in packets) int.parse('${pk['size']}')],
    pts: [for (final pk in packets) int.parse('${pk['pts']}')],
  );
}

/// Task #41: an AAC stream in AVI declares a block size no packet exceeds,
/// so a reader times every packet as one: the header's `nBlockAlign` is
/// avienc's 768 per channel, or the largest packet when one is bigger, and
/// the packets' timestamps follow on with no gap. Returns how many packets
/// were over 768 per channel.
Future<int> expectAacTimedOnce(String what, String path) async {
  final headers = await aviAudioHeaders(path);
  expect(headers, isNotEmpty, reason: '$what: no audio stream header');
  final h = headers.first;
  expect(h.tag, 0x00FF, reason: '$what: AAC');
  final packets = await audioPackets(path);
  final largest = packets.sizes.reduce((a, b) => a > b ? a : b);
  expect(h.largest, largest, reason: '$what: dwSuggestedBufferSize is the largest packet');
  final declared = 768 * h.channels;
  expect(h.blockAlign, largest > declared ? largest : declared,
      reason: '$what: nBlockAlign (largest packet $largest)');
  final gaps = [
    for (var i = 1; i < packets.pts.length; i++)
      if (packets.pts[i] != packets.pts[i - 1] + 1) i,
  ];
  expect(gaps, isEmpty, reason: '$what: audio packets timed as more than one');
  return packets.sizes.where((s) => s > declared).length;
}

Future<int> countFrames(String path) async {
  final s = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
  return int.parse('${s!['nb_read_frames']}');
}

/// The video stream of an AVI as stored: its average rate, the frame count
/// in its header (null frames included: the 600 fps trap of task #30, which
/// `nb_read_frames` hides) and the first frames' times.
Future<({String rate, int stored, List<double> pts})> aviVideo(String path) async {
  final v = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'stream=avg_frame_rate,time_base,nb_frames', '-read_intervals', '%+#3',
    '-show_entries', 'frame=pts_time', '-of', 'json', path,
  ]);
  final s = (v['streams'] as List).first as Map<String, dynamic>;
  return (
    rate: '${s['avg_frame_rate']}',
    stored: int.parse('${s['nb_frames']}'),
    pts: [for (final f in v['frames'] as List) double.parse('${f['pts_time']}')],
  );
}

/// Half the longest of the source's first audio packets, seconds: how far a
/// copied compressed sound cut at a packet may sit from the first picture.
Future<double> halfPacket(String video) async {
  final a = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-read_intervals', '%+#32',
    '-show_entries', 'packet=duration_time', '-of', 'json', video,
  ]);
  var longest = 0.0;
  for (final pk in a['packets'] as List) {
    final d = double.tryParse('${pk['duration_time']}') ?? 0;
    if (d > longest && d < 1) longest = d;
  }
  return longest / 2;
}

