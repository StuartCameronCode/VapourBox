/// HDR sources on an SDR screen, and what kind of Dolby Vision a file is
/// (issue #133).
///
/// The app shows the source through its own ffmpeg calls (timeline
/// thumbnails, the "before" frame) and the worker renders the "after" frame;
/// all three must show an HDR picture the same way or before and after stop
/// comparing like for like. The worker's half is
/// `ColorMetadata::display_tonemap_filter` (worker/src/models/color_metadata.rs).
library;

/// What the Dolby Vision configuration record in ffprobe's stream side data
/// says.
class DolbyVisionInfo {
  /// `dv_profile`: 5, 7, 8, …
  final int? profile;

  /// `dv_bl_signal_compatibility_id`: 0 is no backward-compatible base layer,
  /// 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10.
  final int? compatibilityId;

  const DolbyVisionInfo({this.profile, this.compatibilityId});

  /// Read from an ffprobe `-show_streams` stream map; null when the stream
  /// carries no Dolby Vision configuration record.
  static DolbyVisionInfo? fromStream(Map<String, dynamic> stream) {
    final list = stream['side_data_list'];
    if (list is! List) return null;
    for (final entry in list) {
      if (entry is Map && entry['side_data_type'] == 'DOVI configuration record') {
        return DolbyVisionInfo(
          profile: (entry['dv_profile'] as num?)?.toInt(),
          compatibilityId: (entry['dv_bl_signal_compatibility_id'] as num?)?.toInt(),
        );
      }
    }
    return null;
  }

  /// Profile 5: the base layer is Dolby's IPTPQc2, not YCbCr. Without the
  /// Dolby Vision reshaping — which nothing VapourBox bundles can apply — it
  /// decodes pink and green, in the preview and in the output.
  bool get baseLayerIsUndecodable => profile == 5 || compatibilityId == 0;

  /// "Dolby Vision 8.1", "Dolby Vision 5". Matches the worker's log wording
  /// (`DolbyVision::label`) apart from the word "Profile", which the short
  /// status-bar label leaves out.
  String get label {
    final p = profile;
    final c = compatibilityId;
    if (p == null) return 'Dolby Vision';
    if (c != null && c > 0) return 'Dolby Vision $p.$c';
    return 'Dolby Vision $p';
  }
}

class HdrDisplay {
  HdrDisplay._();

  /// Whether a colour transfer is HDR: PQ (HDR10 and most Dolby Vision base
  /// layers) or HLG.
  static bool isHdrTransfer(String? transfer) =>
      transfer == 'smpte2084' || transfer == 'arib-std-b67';

  /// The short name of a source's dynamic range for the status bar, or null
  /// for SDR.
  static String? rangeLabel({String? transfer, DolbyVisionInfo? dolbyVision}) {
    if (dolbyVision != null) return dolbyVision.label;
    switch (transfer) {
      case 'smpte2084':
        return 'HDR10';
      case 'arib-std-b67':
        return 'HLG';
    }
    return null;
  }

  /// The ffmpeg filter chain that shows an HDR picture on an SDR screen, or
  /// null for an SDR source. Display only: the encode keeps the HDR picture.
  ///
  /// Must stay byte-identical to the worker's
  /// `ColorMetadata::display_tonemap_filter` for the same tags; both sides
  /// assert the same string for the same input. See that function for why
  /// each stage is there — in short: declare the tags (zscale finds no path
  /// from "unspecified"), linearise, map BT.2020 to 709, Hable tone-map, and
  /// hand over rgb24 tagged `gbr` so a JPEG encode doesn't convert with
  /// BT.2020's matrix.
  ///
  /// The tags are the ones the worker would keep (`ColorMetadata::from_raw`),
  /// so pass the same values the job carries.
  static String? toneMapFilter({
    String? matrix,
    String? primaries,
    String? transfer,
    String? range,
  }) {
    if (!isHdrTransfer(transfer)) return null;
    const matrices = {'bt709', 'bt2020nc', 'bt2020c'};
    const primarySet = {'bt709', 'bt2020', 'smpte432'};
    final m = matrices.contains(matrix) ? matrix! : 'bt2020nc';
    final p = primarySet.contains(primaries) ? primaries! : 'bt2020';
    final full = const {'pc', 'jpeg', 'full'}.contains(range);
    return 'setparams=colorspace=$m:color_primaries=$p:color_trc=$transfer'
        ':range=${full ? 'pc' : 'tv'},'
        'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
        'tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,'
        'format=rgb24,setparams=colorspace=gbr';
  }
}
