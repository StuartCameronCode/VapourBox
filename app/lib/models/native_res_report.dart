/// What `vapourbox-worker --detect-native` found: the resolution and kernel a
/// video was upscaled from, for the Descale pass (`worker/src/native_res.rs`).
class NativeResReport {
  /// Whether a native resolution stands out clearly enough to use.
  final bool found;
  final int height;
  final int width;

  /// The Descale pass's kernel id and parameters.
  final String kernel;
  final double bicubicB;
  final double bicubicC;
  final int lanczosTaps;

  /// The best height's error over its neighbours': near 0 a sharp dip.
  final double dip;

  /// Every kernel tried at that height, best first.
  final List<(String, double)> kernels;

  /// Why the analysis failed, when it did.
  final String? error;

  const NativeResReport({
    required this.found,
    required this.height,
    required this.width,
    required this.kernel,
    this.bicubicB = 0,
    this.bicubicC = 0.5,
    this.lanczosTaps = 3,
    this.dip = 1,
    this.kernels = const [],
    this.error,
  });

  const NativeResReport.failed(String this.error)
      : found = false,
        height = 0,
        width = 0,
        kernel = '',
        bicubicB = 0,
        bicubicC = 0.5,
        lanczosTaps = 3,
        dip = 1,
        kernels = const [];

  factory NativeResReport.fromJson(Map<String, dynamic> json) {
    if (json['error'] is String) return NativeResReport.failed(json['error'] as String);
    return NativeResReport(
      found: json['found'] == true,
      height: (json['height'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      kernel: json['kernel'] as String? ?? 'bicubic',
      bicubicB: (json['bicubicB'] as num?)?.toDouble() ?? 0,
      bicubicC: (json['bicubicC'] as num?)?.toDouble() ?? 0.5,
      lanczosTaps: (json['lanczosTaps'] as num?)?.toInt() ?? 3,
      dip: (json['dip'] as num?)?.toDouble() ?? 1,
      kernels: [
        for (final k in (json['kernels'] as List? ?? const []))
          if (k is List && k.length == 2) (k[0].toString(), (k[1] as num).toDouble()),
      ],
    );
  }

  /// The best kernel's display name, e.g. "Bicubic (Catmull-Rom)".
  String get kernelLabel => kernels.isEmpty ? kernel : kernels.first.$1;

  /// The values the Descale pass takes from this report.
  Map<String, dynamic> get descaleValues => {
        'nativeHeight': height,
        'nativeWidth': 0,
        'kernel': kernel,
        'bicubicB': bicubicB,
        'bicubicC': bicubicC,
        'lanczosTaps': lanczosTaps,
      };
}
