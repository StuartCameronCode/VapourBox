import '../services/field_order_detector.dart';
import 'processing_pipeline.dart';

/// How much a pass has to do with the file that is actually loaded.
enum PassRelevance {
  /// The source shows the problem this pass fixes. Worth the user's attention.
  recommended,

  /// Might help, might not — it depends on the source's condition, which
  /// detection can't see. Most passes, most of the time.
  neutral,

  /// The problem this pass fixes cannot be present in this source.
  notApplicable,
}

/// Whether a pass is worth looking at for a given source.
///
/// This exists because the honest way to shorten the pass list is to shorten it
/// *for the file in hand*, and the app already detects enough to do that — scan
/// type, resolution, codec, pixel format and sample aspect all come back from
/// [FieldOrderDetector] before the list is ever shown.
///
/// Two rules keep it useful rather than noisy:
///
/// - **Recommend sparingly.** A badge on nine rows out of thirteen is not a
///   recommendation, it is decoration. Only claims backed by strong evidence
///   from detection are made, which is why most passes come back [neutral] —
///   film dirt, scratches, grain and over-sharpening are all invisible to
///   ffprobe, so the app has nothing to say about them and says nothing.
/// - **Never reorder, never disable.** The pass list's order is the order the
///   passes run in, and a [notApplicable] pass stays enabled and editable —
///   detection is a hint, not an authority, and it is wrong often enough
///   (`ScanType.unknown` exists for a reason) that overriding the user would
///   be worse than saying nothing.
class PassRelevanceResult {
  final PassRelevance level;

  /// Short phrase for the UI, e.g. "source is progressive". Null when
  /// [neutral], because there is nothing to explain.
  final String? reason;

  const PassRelevanceResult(this.level, [this.reason]);

  static const neutral = PassRelevanceResult(PassRelevance.neutral);

  bool get isRecommended => level == PassRelevance.recommended;
  bool get isNotApplicable => level == PassRelevance.notApplicable;
}

/// Standard-definition height. Composite-video artefacts — dot crawl, rainbows,
/// chroma bleed — come from analogue broadcast and tape, so they effectively
/// only appear at or below SD.
const int _sdMaxHeight = 576;

/// Decide how relevant [pass] is to [info].
///
/// Returns [PassRelevanceResult.neutral] for a null [info] (nothing loaded yet)
/// and for anything detection can't speak to.
PassRelevanceResult relevanceFor(PassType pass, VideoInfo? info) {
  if (info == null) return PassRelevanceResult.neutral;

  final isProgressive = info.scanType == ScanType.progressive;
  final isFielded = info.scanType == ScanType.interlaced ||
      info.scanType == ScanType.telecine ||
      info.scanType == ScanType.softTelecine;
  final isSd = info.height <= _sdMaxHeight;

  switch (pass) {
    case PassType.deinterlace:
      if (isFielded) {
        return PassRelevanceResult(
          PassRelevance.recommended,
          'source is ${info.scanType.displayName.toLowerCase()}',
        );
      }
      if (isProgressive) {
        return const PassRelevanceResult(
          PassRelevance.notApplicable,
          'source is progressive',
        );
      }
      // ScanType.unknown — detection failed, so say nothing either way.
      return PassRelevanceResult.neutral;

    case PassType.chromaFixes:
      // Dot crawl, rainbowing and chroma bleed are composite-video faults, so
      // they need an SD fielded source to be plausible.
      if (isSd && isFielded) {
        return const PassRelevanceResult(
          PassRelevance.recommended,
          'SD interlaced source — likely an analogue capture',
        );
      }
      if (isProgressive && !isSd) {
        return const PassRelevanceResult(
          PassRelevance.notApplicable,
          'progressive HD source has no composite artifacts',
        );
      }
      return PassRelevanceResult.neutral;

    case PassType.deblock:
      // MPEG-2 at DVD and broadcast bitrates blocks visibly; nothing else in
      // the metadata is a reliable signal, since ffprobe won't tell us how hard
      // the encoder was pushed.
      if (info.codec.toLowerCase() == 'mpeg2video') {
        return const PassRelevanceResult(
          PassRelevance.recommended,
          'MPEG-2 source — blocking is common',
        );
      }
      return PassRelevanceResult.neutral;

    case PassType.cropResize:
      // A non-square sample aspect means the output shape is a decision the
      // user has to make, whether or not they want to crop or scale.
      if (info.sar != null && info.sar!.isNotEmpty) {
        return PassRelevanceResult(
          PassRelevance.recommended,
          'anamorphic source (${info.sar}) — check pixel aspect',
        );
      }
      return PassRelevanceResult.neutral;

    // Everything below is invisible to detection. Film dirt, scratches, grain,
    // halos, banding and colour casts need eyes on the picture, so the app has
    // no opinion and offers none.
    case PassType.descratch:
    case PassType.spotless:
    case PassType.noiseReduction:
    case PassType.chromaDenoise:
    case PassType.dehalo:
    case PassType.deband:
    case PassType.sharpen:
    case PassType.colorCorrection:
    case PassType.subtitles:
    // Anti-aliasing and stabilisation are tempting to tie to detection —
    // jaggies follow deinterlacing, shake follows handheld capture — but
    // neither is actually visible in the metadata, only plausible from it.
    // Badging every interlaced source would dilute the badge, which is the one
    // thing that makes it worth having.
    case PassType.antiAlias:
    case PassType.stabilize:
    // Orientation is a fact about how the footage was shot, not a defect
    // ffprobe reports — a rotation flag in the container is not the same as
    // the picture being the wrong way round.
    case PassType.geometry:
    case PassType.grain:
      return PassRelevanceResult.neutral;
  }
}
