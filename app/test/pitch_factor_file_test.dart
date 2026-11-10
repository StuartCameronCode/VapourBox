import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/pitch_factor_file.dart';

void main() {
  group('PitchFactorFile.parse', () {
    test('counts bare factors, skipping comments and blank lines', () {
      final info = PitchFactorFile.parse('# log\n1.0012\n\n0.999 # slip\r\n1\n');
      expect(info.isValid, isTrue);
      expect(info.frameCount, 3);
    });

    test('frame,factor files cover up to the highest frame', () {
      final info = PitchFactorFile.parse('0,1.001\n5 0.998\n2\t1.0\n');
      expect(info.frameCount, 6);
    });

    test('names the first bad line', () {
      expect(PitchFactorFile.parse('1.0\nabc\n').error, contains('Line 2'));
      expect(PitchFactorFile.parse('-1\n').error, contains('Line 1'));
      expect(PitchFactorFile.parse('x,1.0\n').error, contains('Line 1'));
    });

    test('rejects empty and mixed files', () {
      expect(PitchFactorFile.parse('# nothing\n').isValid, isFalse);
      expect(PitchFactorFile.parse('1.0\n3,1.0\n').isValid, isFalse);
    });

    test('describes coverage against the video', () {
      const info = PitchFactorFileInfo(100);
      expect(info.describe(100), contains('one per frame'));
      expect(info.describe(120), contains('left uncorrected'));
      expect(info.describe(80), contains('ignored'));
    });
  });

  group('PitchFactorFile.findSidecar', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('vb_pitch'));
    tearDown(() async => dir.delete(recursive: true));

    test('finds the sidecars in priority order', () async {
      final video = p.join(dir.path, 'reel1.mp4');
      expect(PitchFactorFile.findSidecar(video), isNull);

      await File(p.join(dir.path, 'reel1_pitch.txt')).writeAsString('1.0');
      expect(PitchFactorFile.findSidecar(video), endsWith('reel1_pitch.txt'));

      await File(p.join(dir.path, 'reel1.pitch.txt')).writeAsString('1.0');
      expect(PitchFactorFile.findSidecar(video), endsWith('reel1.pitch.txt'));

      await File(p.join(dir.path, 'reel1.mp4.pitch.txt')).writeAsString('1.0');
      expect(PitchFactorFile.findSidecar(video), endsWith('reel1.mp4.pitch.txt'));
    });

    test('a dot in a folder name is not an extension', () {
      final c = PitchFactorFile.sidecarCandidates('/films/v1.2/reel');
      expect(c, contains('/films/v1.2/reel.pitch.txt'));
    });
  });
}
