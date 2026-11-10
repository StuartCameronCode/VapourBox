/// Which colour tags FFmpeg accepts, and the filter that clears the ones it
/// doesn't before the app's own decodes convert a frame.
///
/// The twin of `decode_tag_neutraliser` in
/// worker/src/models/color_metadata.rs: the lists are that file's `MATRICES`,
/// `PRIMARIES` and `TRANSFERS`, and the filter must be byte-identical for the
/// same tags. `color_tags_test.dart` reads the Rust source and checks both.
library;

class ColorTags {
  ColorTags._();

  /// `-colorspace` values (worker `MATRICES`).
  static const matrices = [
    'rgb', 'bt709', 'fcc', 'bt470bg', 'smpte170m', 'smpte240m', 'ycgco',
    'bt2020nc', 'bt2020c', 'smpte2085', 'chroma-derived-nc',
    'chroma-derived-c', 'ictcp',
  ];

  /// `-color_primaries` values (worker `PRIMARIES`).
  static const primaries = [
    'bt709', 'bt470m', 'bt470bg', 'smpte170m', 'smpte240m', 'film', 'bt2020',
    'smpte428', 'smpte431', 'smpte432', 'jedec-p22', 'ebu3213',
  ];

  /// `-color_trc` values (worker `TRANSFERS`).
  static const transfers = [
    'bt709', 'gamma22', 'gamma28', 'smpte170m', 'smpte240m', 'linear',
    'log100', 'log316', 'iec61966-2-4', 'bt1361e', 'iec61966-2-1',
    'bt2020-10', 'bt2020-12', 'smpte2084', 'smpte428', 'arib-std-b67',
  ];

  static bool _isInvalid(String? value, List<String> allowed,
      [List<String> alsoValid = const []]) {
    final v = value?.trim().toLowerCase();
    if (v == null || v.isEmpty || v == 'unknown' || v == 'n/a') return false;
    return !allowed.contains(v) && !alsoValid.contains(v);
  }

  /// The `setparams` that goes FIRST in the `-vf` of every app decode of the
  /// source that converts its pixel format (the "before" frame, timeline
  /// thumbnails), or null when every tag is usable. Takes ffprobe's RAW
  /// values — `colorTag` forwards `reserved` for exactly this.
  ///
  /// FFmpeg 9's scaler refuses a frame tagged `reserved` (ProRes writes code
  /// 0 for "unknown", which FFmpeg reads as reserved), so without this the
  /// decode fails and the Original side shows "No preview". Only an invalid
  /// tag is cleared, each on its own: clearing a valid matrix changes pixels.
  /// `gbr` (ffprobe's name for the RGB identity matrix) is left alone.
  static String? decodeNeutraliser({
    String? matrix,
    String? primaries,
    String? transfer,
  }) {
    final params = [
      if (_isInvalid(primaries, ColorTags.primaries)) 'color_primaries=unknown',
      if (_isInvalid(transfer, transfers)) 'color_trc=unknown',
      if (_isInvalid(matrix, matrices, const ['gbr'])) 'colorspace=unknown',
    ];
    return params.isEmpty ? null : 'setparams=${params.join(':')}';
  }
}
