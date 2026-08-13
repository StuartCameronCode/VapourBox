import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/views/dropped_paths.dart';

/// `isVideoFile` is now the single definition behind both drop targets (the drop
/// zone and the queue panel), which previously kept their own copies of the
/// extension list.
void main() {
  group('isVideoFile', () {
    test('accepts the formats the app reads', () {
      for (final name in [
        'a.avi', 'a.mov', 'a.mp4', 'a.mkv', 'a.mxf', 'a.m2v', 'a.mpg',
        'a.mpeg', 'a.ts', 'a.vob', 'a.dv', 'a.mts', 'a.m2ts', 'a.wmv',
        'a.webm', 'a.flv',
      ]) {
        expect(isVideoFile(name), isTrue, reason: name);
      }
    });

    test('is case-insensitive', () {
      expect(isVideoFile('CLIP.MP4'), isTrue);
      expect(isVideoFile('VTS_01_1.VOB'), isTrue);
      expect(isVideoFile('Movie.MkV'), isTrue);
    });

    test('rejects non-video files', () {
      for (final name in [
        'notes.txt', 'VIDEO_TS.IFO', 'audio.wav', 'image.png', 'no-extension',
        'archive.mp4.zip',
      ]) {
        expect(isVideoFile(name), isFalse, reason: name);
      }
    });

    test('matches on full paths', () {
      expect(isVideoFile('/Users/me/My Videos/holiday.mp4'), isTrue);
      expect(isVideoFile(r'C:\Users\me\holiday.mkv'), isTrue);
      expect(isVideoFile('/Users/me/mp4/readme.md'), isFalse);
    });
  });
}
