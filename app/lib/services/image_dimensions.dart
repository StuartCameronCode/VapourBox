import 'dart:typed_data';
import 'dart:ui' show Size;

/// The pixel dimensions stored in an encoded PNG or JPEG header, or null for
/// anything else or a truncated header.
///
/// The preview needs the frame's real size to show it at 1:1 (issue #8): the
/// source frame is a JPEG from ffmpeg and the processed frame a PNG from the
/// worker. Reading the header is synchronous, so the 1:1 scale is right on
/// the first build rather than one async decode later.
Size? encodedImageSize(Uint8List bytes) {
  if (_isPng(bytes)) {
    // Signature (8) + IHDR length (4) + "IHDR" (4), then width and height.
    if (bytes.length < 24) return null;
    final data = ByteData.sublistView(bytes);
    return _size(data.getUint32(16), data.getUint32(20));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return _jpegSize(bytes);
  }
  return null;
}

bool _isPng(Uint8List b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

/// Walks the marker segments to the first start-of-frame, which holds the
/// height then the width.
Size? _jpegSize(Uint8List b) {
  final data = ByteData.sublistView(b);
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    // Fill bytes before a marker.
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // Markers with no length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final length = data.getUint16(i + 2);
    // SOF0-SOF15, except DHT (C4), JPG (C8) and DAC (CC).
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (i + 9 > b.length) return null;
      return _size(data.getUint16(i + 7), data.getUint16(i + 5));
    }
    i += 2 + length;
  }
  return null;
}

Size? _size(int width, int height) =>
    width > 0 && height > 0 ? Size(width.toDouble(), height.toDouble()) : null;
