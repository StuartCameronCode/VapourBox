// Run once, before the app's probe code was deleted: copy into app/test at
// commit 7c9de94 (task #50 stage A, whose app/lib still holds the Dart probe
// rules) and `flutter test` it. Prints the app's and the model's values per
// fixture. Paths are relative to app/ (deps/ and worker/target/debug/).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';

void main() {
  test('parity', () async {
    const ffprobe = '../deps/macos-arm64/ffmpeg/ffprobe';
    final worker = '../worker/target/debug/vapourbox-worker';
    final files = Directory('../Tests/TestResources').listSync().whereType<File>()
        .where((f) => RegExp(r'\.(mp4|mkv|mov|avi|ts|mpg|vob)$').hasMatch(f.path)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var bad = 0;
    for (final f in files) {
      final r = await Process.run(ffprobe, ['-v','quiet','-print_format','json','-show_streams','-show_format','-select_streams','v:0', f.path]);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final v = (j['streams'] as List).first as Map<String, dynamic>;
      final fmt = j['format'] as Map<String, dynamic>;
      double? rat(String? s) { final p = s?.split('/'); if (p == null || p.length != 2) return null; final n = double.tryParse(p[0]), d = double.tryParse(p[1]); return n != null && d != null && d != 0 ? n / d : null; }
      final rr = rat(v['r_frame_rate'] as String?), ar = rat(v['avg_frame_rate'] as String?);
      final fps = FieldOrderDetector.selectFrameRate(rr, ar);
      final dur = double.tryParse('${fmt['duration']}');
      final sdur = double.tryParse('${v['duration']}');
      final start = await FieldOrderDetector.probeVideoStart(ffprobe, f.path,
          streamStart: double.tryParse('${v['start_time']}'), containerStart: double.tryParse('${fmt['start_time']}'));
      final count = FieldOrderDetector.frameCountFor(storedFrames: int.tryParse('${v['nb_frames']}'), rFrameRate: rr, avgFrameRate: ar, duration: sdur ?? dur, frameRate: fps)
          ?? await FieldOrderDetector.frameCountWithoutStoredCount(ffprobe, f.path, streamDuration: sdur, containerDuration: dur, start: start, frameRate: fps,
              streamStart: double.tryParse('${v['start_time']}'), formatName: fmt['format_name'] as String?);
      final delay = await FieldOrderDetector.probeDecoderDelay(ffprobe, f.path, hasBFrames: v['has_b_frames'] as int?, videoStart: start.offset);
      final plan = await FieldOrderDetector.probeSeekPlan(ffprobe, f.path, formatName: fmt['format_name'] as String?);
      final grid = await FieldOrderDetector.probeSourceGrid(ffprobe, f.path, frameRate: fps ?? 0);
      final m = jsonDecode((await Process.run(worker, ['--probe-source', f.path])).stdout as String)['video'] as Map<String, dynamic>;
      final app = [count, start.offset.toStringAsFixed(6), delay, plan?.preroll.toStringAsFixed(6), grid == null ? null : '${grid.rateNum}/${grid.rateDen}@${grid.origin.toStringAsFixed(6)}', fps];
      final g = m['sourceGrid'] as Map?;
      final model = [m['frameCount'], (m['videoStartOffset'] as num).toStringAsFixed(6), m['decoderDelayFrames'], (m['seekPlan'] as Map?)?['preroll']?.toStringAsFixed(6), g == null ? null : '${g['rateNum']}/${g['rateDen']}@${(g['origin'] as num).toStringAsFixed(6)}', m['frameRate']];
      final same = app.toString() == model.toString();
      if (!same) bad++;
      // ignore: avoid_print
      print('${same ? "OK  " : "DIFF"} ${f.uri.pathSegments.last} app=$app model=$model');
    }
    // ignore: avoid_print
    print('differences: $bad');
  });
}
