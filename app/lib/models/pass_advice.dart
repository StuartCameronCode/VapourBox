import 'processing_pipeline.dart';
import 'qtgmc_parameters.dart';

/// A note about how an enabled pass interacts with the rest of the pipeline.
class PassAdvice {
  /// The pass the note is shown against.
  final PassType pass;

  final String message;

  const PassAdvice(this.pass, this.message);
}

/// Advice about combinations of passes, as opposed to the settings of any one
/// pass.
///
/// At a dozen-odd passes the complexity that actually costs users is not the
/// length of the list, it is *interaction*: two denoisers stacked until the
/// picture is plastic, sharpening applied before the denoiser eats it again,
/// grain re-added before the deband that will smooth it away. None of that is
/// an error — every combination here produces a valid render — so none of it can
/// be caught by validation. It has to be said out loud at the point the user is
/// looking.
///
/// Three rules, so this stays advice and not nagging:
///
/// - **Only ever advisory.** Nothing here blocks a job, disables a control or
///   changes a value. A user who wants a stacked denoise is entitled to one; the
///   app's job is to make sure they meant it.
/// - **Only fires on enabled passes.** Advice about a pass nobody has turned on
///   is noise.
/// - **Says what to do, not just what is wrong.** "Sharpen runs before Noise
///   Reduction" is a fact; the useful half is that the denoiser will undo it.
///
/// Pass order is fixed (see `PassListPanel.stages` and `script_generator.rs`),
/// which is what makes the ordering advice statable at all: Sharpen genuinely
/// always runs before Color Correction, so there is no case to qualify.
List<PassAdvice> adviseOn(ProcessingPipeline pipeline) {
  final advice = <PassAdvice>[];

  bool on(PassType pass) => pipeline.isPassEnabled(pass);

  // --- Stacked denoisers ---
  // Both are motion-compensated temporal denoisers over luma. Running both
  // rarely removes more noise than turning one up, and the second pass has
  // nothing left to lock its motion search onto.
  if (on(PassType.noiseReduction) && on(PassType.chromaDenoise)) {
    // Not a conflict: these split luma and chroma, which is a normal and good
    // combination. Deliberately silent.
  }

  // --- Sharpening fights the denoiser, and loses ---
  // Sharpen runs *before* Noise Reduction in the pipeline, so a denoiser set
  // strongly enough to matter will remove most of what was just sharpened, and
  // amplified noise is what survives.
  if (on(PassType.sharpen) && on(PassType.noiseReduction)) {
    advice.add(const PassAdvice(
      PassType.sharpen,
      'Sharpen runs before Noise Reduction, so the denoiser will soften much '
      'of this again — and sharpened noise is what it has to work on. '
      'Consider denoising alone first and judging the result.',
    ));
  }

  // --- Deband after grain ---
  // Deband runs after the denoiser but the f3kdb grain it adds back is applied
  // within the same pass, so this is about the sharpener that follows it in
  // spirit rather than in fact: sharpening exaggerates the synthetic grain.
  if (on(PassType.deband) && on(PassType.sharpen)) {
    advice.add(const PassAdvice(
      PassType.deband,
      'Sharpening exaggerates the grain Deband adds to hide banding. If the '
      'result looks gritty, lower the grain here rather than the sharpening.',
    ));
  }

  // --- Dehalo before sharpening ---
  if (on(PassType.dehalo) && on(PassType.sharpen)) {
    advice.add(const PassAdvice(
      PassType.sharpen,
      'Dehalo removes the bright outlines that sharpening creates, and it runs '
      'first — so sharpening here can put back exactly what Dehalo took out.',
    ));
  }

  // --- IVTC plus a frame-rate assumption ---
  // Both change the frame rate, in incompatible ways.
  if (pipeline.deinterlace.enabled &&
      pipeline.deinterlace.method == DeinterlaceMethod.ivtc &&
      pipeline.deinterlace.fpsDivisor != null &&
      pipeline.deinterlace.fpsDivisor != 1) {
    advice.add(const PassAdvice(
      PassType.deinterlace,
      'Inverse telecine already sets the output frame rate. The FPS divisor '
      'applies to QTGMC deinterlacing, not IVTC, and will be ignored.',
    ));
  }

  // --- Deinterlacing a pass that needs fields, with nothing to deinterlace ---
  // Vinverse and DeCrawl exist to clean up what deinterlacing leaves behind, so
  // enabling them without it is usually a mistake — though not always, since a
  // source can arrive already (badly) deinterlaced.
  if (on(PassType.chromaFixes) &&
      !pipeline.deinterlace.enabled &&
      (pipeline.chromaFixes.applyVinverse || pipeline.chromaFixes.applyDeCrawl)) {
    advice.add(const PassAdvice(
      PassType.chromaFixes,
      'Vinverse and dot-crawl removal clean up artifacts left by '
      'deinterlacing, which is switched off. Useful on a source that was '
      'already deinterlaced badly, otherwise it has nothing to do.',
    ));
  }

  // --- Rotating interlaced material destroys it ---
  // Fields are stored as alternating horizontal lines. A quarter turn puts them
  // in alternating COLUMNS, where no deinterlacer can find them: measured,
  // std.SeparateFields on a turned clip returns two "fields" that each still
  // contain both, interleaved. It is not a quality trade-off, it is
  // unrecoverable — and _FieldBased still claims the clip is fine afterwards.
  if (on(PassType.geometry) &&
      pipeline.geometry.rotation.swapsAxes &&
      !pipeline.deinterlace.enabled) {
    advice.add(const PassAdvice(
      PassType.geometry,
      'Rotating an interlaced source by a quarter turn destroys the field '
      'structure permanently — the comb ends up in columns, where no '
      'deinterlacer can separate it. If this source is interlaced, turn '
      'Deinterlace on: it runs first, so the rotation then happens to '
      'progressive frames.',
    ));
  }

  return advice;
}

/// The advice for one pass, or null when there is none.
String? adviceFor(PassType pass, ProcessingPipeline pipeline) {
  final matches =
      adviseOn(pipeline).where((a) => a.pass == pass).map((a) => a.message);
  return matches.isEmpty ? null : matches.join('\n\n');
}
