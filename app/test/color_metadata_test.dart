// Colour tags are read from ffprobe here and re-declared on the encoder by the
// worker. ffprobe reports the literal string "unknown" for an untagged stream,
// and forwarding that as though it were a value would put nonsense on the
// ffmpeg command line — so it is dropped on the way in as well as on the way
// out (worker-side, in ColorMetadata::from_raw).

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';

void main() {
  group('colorTag', () {
    test('reads a real tag', () {
      expect(colorTag({'color_space': 'bt709'}, 'color_space'), 'bt709');
      expect(colorTag({'color_range': 'pc'}, 'color_range'), 'pc');
    });

    test('treats ffprobe\'s untagged spellings as absent', () {
      for (final v in ['unknown', 'N/A', '', '   ']) {
        expect(colorTag({'color_space': v}, 'color_space'), isNull,
            reason: '"$v" is not a colour matrix');
      }
    });

    test('a missing key is absent, not an error', () {
      expect(colorTag(const {}, 'color_space'), isNull);
    });

    test('forwards a value FFmpeg rejects, such as ProRes\'s reserved', () {
      // Deliberate: the worker needs the raw tag to know the decoder must
      // clear it (VideoJob::decode_tag_neutraliser). The encoder's tags drop
      // it in ColorMetadata::from_raw.
      expect(colorTag({'color_primaries': 'reserved'}, 'color_primaries'),
          'reserved');
    });

    test('trims surrounding whitespace', () {
      expect(colorTag({'color_space': ' bt709 '}, 'color_space'), 'bt709');
    });
  });
}
