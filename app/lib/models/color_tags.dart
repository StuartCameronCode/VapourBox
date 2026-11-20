/// Which colour tags FFmpeg accepts and can convert, and the filter that
/// fixes the ones it can't before the app's own decodes convert a frame.
///
/// The twin of `decode_tag_neutraliser` in
/// worker/src/models/color_metadata.rs: the lists are that file's `MATRICES`,
/// `SCALER_MATRICES`, `PRIMARIES` and `TRANSFERS`, and the filter must be
/// byte-identical for the same tags
/// (`Tests/TestResources/decode_neutraliser_cases.json`). `color_tags_test.dart`
/// reads the Rust source and checks both.
library;

class ColorTags {
  ColorTags._();

  /// `-colorspace` values (worker `MATRICES`).
  static const matrices = [
    'rgb', 'bt709', 'fcc', 'bt470bg', 'smpte170m', 'smpte240m', 'ycgco',
    'bt2020nc', 'bt2020c', 'smpte2085', 'chroma-derived-nc',
    'chroma-derived-c', 'ictcp',
  ];

  /// The [matrices] FFmpeg 9's scaler can convert a frame from (worker
  /// `SCALER_MATRICES`, task #76). A frame tagged with any other fails every
  /// decode that converts its pixel format.
  static const scalerMatrices = [
    'rgb', 'bt709', 'fcc', 'bt470bg', 'smpte170m', 'smpte240m', 'bt2020nc',
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

  /// The matrix the preview's `scale=in_color_matrix=` names for raw tags
  /// [matrix] / [primaries], or null to leave it out (swscale then reads
  /// BT.601). The twin of `ColorMetadata::swscale_matrix` (task #73): FFmpeg
  /// 9's `scale` has no conversion for `ycgco`, `bt2020c`, `smpte2085`,
  /// `chroma-derived-*` or `ictcp`, so those are mapped to the nearest matrix
  /// it has, or left out.
  static String? scaleMatrix(String? matrix, String? primaries) {
    final m = matrix?.trim().toLowerCase();
    if (m == null || !matrices.contains(m)) return null;
    final prim = primaries?.trim().toLowerCase();
    final derived = prim == 'bt709' || prim == 'bt2020' ? prim : null;
    return switch (m) {
      'bt709' || 'fcc' || 'bt470bg' || 'smpte170m' || 'smpte240m' ||
      'bt2020nc' =>
        m,
      'bt2020c' || 'ictcp' => 'bt2020',
      'chroma-derived-nc' || 'chroma-derived-c' => derived,
      _ => null, // rgb, ycgco, smpte2085
    };
  }

  /// What a frame tagged [matrix] (raw) is converted as when FFmpeg's scaler
  /// can't convert that matrix itself, or null when it can (or there is
  /// none). The preview's reading ([scaleMatrix]) as a `setparams` value:
  /// `bt2020c`/`ictcp` → `bt2020nc`, `chroma-derived-*` by [primaries],
  /// `ycgco`/`smpte2085` → `unknown`. Twin of `ColorMetadata::scaler_stand_in`.
  static String? scalerStandIn(String? matrix, String? primaries) {
    final m = matrix?.trim().toLowerCase();
    if (m == null || !matrices.contains(m) || scalerMatrices.contains(m)) {
      return null;
    }
    final prim = primaries?.trim().toLowerCase();
    final known = ColorTags.primaries.contains(prim) ? prim : null;
    return switch (scaleMatrix(m, known)) {
      'bt2020' => 'bt2020nc',
      final String s => s,
      null => 'unknown',
    };
  }

  /// The `setparams` that goes FIRST in the `-vf` of every app decode of the
  /// source that converts its pixel format (the "before" frame, timeline
  /// thumbnails), or null when FFmpeg's scaler can convert the frame with its
  /// tags as they are. Takes ffprobe's RAW values — `colorTag` forwards
  /// `reserved` for exactly this.
  ///
  /// FFmpeg 9's scaler fails the decode on an invalid tag (ProRes writes code
  /// 0 for "unknown", which FFmpeg reads as `reserved`), cleared to unknown
  /// each on its own, and on a valid matrix it has no conversion for (task
  /// #76), replaced by [scalerStandIn]. Without this the Original side shows
  /// "No preview". A tag the scaler converts is never touched: clearing a
  /// valid matrix changes pixels. `gbr` (ffprobe's name for the RGB identity
  /// matrix) is left alone.
  static String? decodeNeutraliser({
    String? matrix,
    String? primaries,
    String? transfer,
  }) {
    final standIn = scalerStandIn(matrix, primaries);
    final params = [
      if (_isInvalid(primaries, ColorTags.primaries)) 'color_primaries=unknown',
      if (_isInvalid(transfer, transfers)) 'color_trc=unknown',
      if (_isInvalid(matrix, matrices, const ['gbr']))
        'colorspace=unknown'
      else if (standIn != null)
        'colorspace=$standIn',
    ];
    return params.isEmpty ? null : 'setparams=${params.join(':')}';
  }
}
