import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/disc_detector.dart';

/// What `DiscDetector.findDvdRoot` must decide for each folder shape a user can
/// drop on the app. A wrong answer here is silent either way: a ripped DVD
/// misread as a plain folder queues dozens of raw VOB fragments, and a plain
/// folder misread as a DVD sends the user to a title picker for a disc that
/// isn't there.
void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('vb_dvd_folder_test_');
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  /// Creates [relativePaths] as empty files under a folder named [name].
  Future<Directory> makeFolder(String name, List<String> relativePaths) async {
    final dir = Directory('${sandbox.path}/$name');
    await dir.create(recursive: true);
    for (final rel in relativePaths) {
      final file = File('${dir.path}/$rel');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(const []);
    }
    return dir;
  }

  group('ordinary folders are not DVDs', () {
    test('a folder of video files', () async {
      final dir = await makeFolder('holiday', ['a.mp4', 'b.mkv', 'c.avi']);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('an empty folder', () async {
      final dir = await makeFolder('empty', []);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('a folder of loose VOBs with no IFO — not extractable as a disc',
        () async {
      final dir = await makeFolder('vobs', ['clip1.vob', 'clip2.vob']);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('a stray IFO among unrelated videos does not hijack the folder',
        () async {
      final dir = await makeFolder('mixed', ['VIDEO_TS.IFO', 'a.mp4', 'b.mkv']);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('a path that does not exist', () async {
      expect(await DiscDetector.findDvdRoot('${sandbox.path}/nope'), isNull);
    });
  });

  group('ripped DVDs are DVDs', () {
    test('folder containing VIDEO_TS/ returns the folder itself', () async {
      final dir = await makeFolder('MyDisc', [
        'VIDEO_TS/VIDEO_TS.IFO',
        'VIDEO_TS/VTS_01_0.IFO',
        'VIDEO_TS/VTS_01_1.VOB',
      ]);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });

    test('the VIDEO_TS directory itself returns its parent', () async {
      final dir = await makeFolder('MyDisc2', ['VIDEO_TS/VIDEO_TS.IFO']);
      final videoTs = '${dir.path}/VIDEO_TS';
      expect(await DiscDetector.findDvdRoot(videoTs), dir.path);
    });

    test('lowercase video_ts is recognised', () async {
      final dir = await makeFolder('MyDisc3', ['video_ts/video_ts.ifo']);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });

    test('a flat rip (VIDEO_TS contents, no wrapping directory)', () async {
      final dir = await makeFolder('Wedding 1998', [
        'VIDEO_TS.IFO',
        'VIDEO_TS.BUP',
        'VTS_01_0.IFO',
        'VTS_01_1.VOB',
        'VTS_01_2.VOB',
      ]);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });

    test('a flat rip with only a VTS IFO (no VIDEO_TS.IFO)', () async {
      final dir = await makeFolder('Concert', [
        'VTS_01_0.IFO',
        'VTS_01_1.VOB',
      ]);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });

    test('a flat rip in lowercase', () async {
      final dir = await makeFolder('lower', [
        'video_ts.ifo',
        'vts_01_1.vob',
      ]);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });

    test('a VIDEO_TS subdirectory wins over loose videos beside it', () async {
      final dir = await makeFolder('BothShapes', [
        'VIDEO_TS/VIDEO_TS.IFO',
        'VIDEO_TS/VTS_01_1.VOB',
        'extra.mp4',
      ]);
      expect(await DiscDetector.findDvdRoot(dir.path), dir.path);
    });
  });

  group('edge cases', () {
    test('a VIDEO_TS directory with no IFO is not a DVD', () async {
      final dir = await makeFolder('Hollow', ['VIDEO_TS/readme.txt']);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('a folder named VIDEO_TS but empty is not a DVD', () async {
      final dir = await makeFolder('VIDEO_TS', []);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });

    test('VTS numbering must be two digits followed by _0', () async {
      final dir = await makeFolder('NotIfo', ['VTS_1_1.IFO', 'VTS_01_1.VOB']);
      expect(await DiscDetector.findDvdRoot(dir.path), isNull);
    });
  });
}
