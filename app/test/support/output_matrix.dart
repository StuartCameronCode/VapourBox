/// The output conformance matrix (task #49): every valid container × audio
/// mode × source class × trim, generated from the enums and the output
/// capability table, and the oracle that says what each case's output must
/// be. Pure, no I/O: `output_matrix_cases_test.dart` (push gate) checks the
/// cases, `integration_output_conformance_test.dart` (heavy) encodes them.
///
/// The sources are `generate_output_conformance.sh`'s: one content (160x120,
/// 25 fps, 100 pictures, white frames at 5, 30, 55 and 80 with a click at
/// each) in four source classes.
library;

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';

/// Every source has this many pictures, at this rate.
const matrixPictures = 100;
const matrixFps = 25;

/// The pictures that are white (each with its click).
const matrixFlashes = [5, 30, 55, 80];

/// The four source classes.
enum SourceClass {
  /// H.264 + AAC in MP4, sound and picture together.
  plain('plain', 'conf_plain.mp4', 'aac'),

  /// H.264 + MP2 in MPEG-TS, the picture 1 s after the sound (DVB-T).
  lateVideo('late-video', 'conf_late_video.ts', 'mp2'),

  /// MPEG-4 ASP with B-frames + MP3 in AVI (decode-order timestamps).
  delayedAvi('delayed-avi', 'conf_delayed.avi', 'mp3'),

  /// MPEG-2 + MP2 in MPEG-PS whose clock resets at picture 51, decoded from
  /// the app's joined copy (`TimestampContinuityService`).
  resetPs('reset-ps', 'conf_reset.mpg', 'mp2');

  const SourceClass(this.id, this.file, this.audioCodec);
  final String id;
  final String file;

  /// The source's sound, as ffprobe names it.
  final String audioCodec;

  /// The decoder Audio Restoration's render reads this sound with, when it
  /// is not FFmpeg's default: the float decoder for MPEG layers I and II,
  /// whose fixed-point default rounds differently after a seek (mirrors
  /// `audio_restoration::render_decoder`, task #58).
  String? get renderDecoder => switch (audioCodec) {
        'mp1' => 'mp1float',
        'mp2' => 'mp2float',
        _ => null,
      };

  /// How far the picture starts after the sound, as the fixture was made.
  double get nominalVideoStart => this == lateVideo ? 1.0 : 0.0;
}

/// The trims: untrimmed, one starting 0.08 s in (inside the near-start seek
/// rules: `COUNT_SEEK_BELOW`, task #22's 0.13 s), one mid-GOP (a copy has
/// pre-roll).
enum MatrixTrim {
  untrimmed('untrimmed', null, null),
  nearStart('near-start', 2, 51),
  mid('mid', 40, 89);

  const MatrixTrim(this.id, this.start, this.end);
  final String id;
  final int? start;
  final int? end;

  int get firstPicture => start ?? 0;
  int get pictures => start == null ? matrixPictures : end! - start! + 1;

  /// The white frames inside the window, as source picture numbers.
  List<int> get flashes => [
        for (final n in matrixFlashes)
          if (n >= firstPicture && n < firstPicture + pictures) n,
      ];
}

/// How the case treats the sound.
enum AudioKind {
  /// Passthrough: the source's sound copied.
  passthrough,

  /// Convert to [MatrixCase.audioCodec].
  convert,

  /// Audio Restoration on (drift correction only, which the fixtures never
  /// trigger: a render with every sample kept), under Passthrough.
  restore,

  /// Audio Restoration as [restore], under Convert to AAC (task #38's
  /// "restored and trimmed").
  restoreConvert,
}

/// What a lossless output's sound must match.
enum LosslessCheck {
  none,

  /// The output's audio payload is a contiguous run of the source's bytes.
  copy,

  /// The output's samples are the source's decoded samples, to the output's
  /// sample depth.
  exact,
}

class MatrixCase {
  const MatrixCase({
    required this.container,
    required this.video,
    required this.audio,
    required this.source,
    required this.trim,
    this.audioCodec,
  });

  final ContainerFormat container;
  final VideoCodec video;
  final AudioKind audio;
  final AudioCodec? audioCodec;
  final SourceClass source;
  final MatrixTrim trim;

  /// The default video codec of a container's rows: a fast offered one.
  /// MP4/MOV: H.264 (ultrafast); MKV/AVI: FFV1.
  static VideoCodec defaultVideo(ContainerFormat k) =>
      k.isIsoMedia ? VideoCodec.h264 : VideoCodec.ffv1;

  String get _audioId => switch (audio) {
        AudioKind.passthrough => 'passthrough',
        AudioKind.convert => 'convert-${audioCodec!.value}',
        AudioKind.restore => 'restore',
        AudioKind.restoreConvert => 'restore-convert-aac',
      };

  /// A stable name: `avi/convert-libmp3lame/delayed-avi/near-start`, with the
  /// video codec after the container when it isn't the container's default.
  String get id {
    final v = video == defaultVideo(container) ? '' : '+${video.name}';
    return '${container.value}$v/$_audioId/${source.id}/${trim.id}';
  }

  AudioMode get audioMode => switch (audio) {
        AudioKind.passthrough || AudioKind.restore => AudioMode.passthrough,
        AudioKind.convert || AudioKind.restoreConvert => AudioMode.convert,
      };

  AudioCodec get convertCodec =>
      audio == AudioKind.restoreConvert ? AudioCodec.aac : (audioCodec ?? AudioCodec.aac);

  bool get restores => audio == AudioKind.restore || audio == AudioKind.restoreConvert;

  // ---------------------------------------------------------------- oracle

  /// Pictures the output holds.
  int get expectedPictures => trim.pictures;

  /// Whether the output may start its picture after a copied sound's
  /// pre-roll: a stream copy keeps packets from the keyframe before a trim's
  /// in-point, and MKV/MP4/MOV store that as a later video start (AVI cuts
  /// it, task #24). Its length depends on the source's GOP, so the first
  /// picture is then checked against the flashes, not a constant.
  bool get keepsCopyPreRoll =>
      audio == AudioKind.passthrough && container.storesStreamStart && trim != MatrixTrim.untrimmed;

  /// Where the output's first picture sits, given where the source's picture
  /// starts after its sound ([sourceVideoStart], the app's own probe): the
  /// gap is kept only untrimmed and only where the container records a
  /// stream start (AVI starts both with the picture, task #30). Null when
  /// [keepsCopyPreRoll].
  double? expectedFirstPts(double sourceVideoStart) {
    if (keepsCopyPreRoll) return null;
    return container.storesStreamStart && trim == MatrixTrim.untrimmed ? sourceVideoStart : 0;
  }

  /// The output time of each white frame in the window, given the output's
  /// own first picture time [firstPts].
  List<double> expectedFlashTimes(double firstPts) => [
        for (final n in trim.flashes) (n - trim.firstPicture) / matrixFps + firstPts,
      ];

  /// The output's audio codec, as ffprobe names it.
  String get expectedAudioCodec {
    switch (audio) {
      case AudioKind.passthrough:
        return source.audioCodec;
      case AudioKind.convert:
      case AudioKind.restoreConvert:
        return _probeName(convertCodec);
      case AudioKind.restore:
        return video.isProRes || video.isUncompressed ? 'pcm_s24le' : container.restoredPassthrough;
    }
  }

  /// Whether ffprobe's `codec_name` for the output's sound is the expected
  /// one. MP4 files MPEG-1 Layer II under the object type it shares with
  /// Layer III, so ffprobe names a copied MP2 mp3 or mp2 depending on how
  /// much it parses (the bytes are unchanged; the copy check compares them).
  bool audioCodecMatches(String probed) =>
      probed == expectedAudioCodec ||
      (expectedAudioCodec == 'mp2' && probed == 'mp3' && container == ContainerFormat.mp4);

  /// What a lossless output's sound is checked against.
  LosslessCheck get lossless {
    if (audio == AudioKind.passthrough) return LosslessCheck.copy;
    final codec = expectedAudioCodec;
    return codec == 'flac' || codec.startsWith('pcm_') ? LosslessCheck.exact : LosslessCheck.none;
  }

  /// The decoder the source's sound is decoded with for [LosslessCheck.exact]:
  /// a restored track is the render's decode ([SourceClass.renderDecoder]);
  /// a Convert is FFmpeg's default decoder. Null for the default.
  String? get referenceDecoder => restores ? source.renderDecoder : null;

  /// Whether the AVI AAC block-size rule applies (task #41).
  bool get checksAacBlockAlign =>
      container.timesAudioByBlockAlign && expectedAudioCodec == 'aac';
}

/// The ffprobe `codec_name` each Convert codec's encoder writes.
String _probeName(AudioCodec c) => switch (c) {
      AudioCodec.mp3 => 'mp3',
      AudioCodec.opus => 'opus',
      _ => c.value,
    };

/// The extra video rows: only where the video codec changes an audio
/// decision (ProRes: a 24-bit PCM restored track, no faststart; AV1: its own
/// container pair).
const extraVideoRows = [
  (ContainerFormat.mov, VideoCodec.proresProxy),
  (ContainerFormat.mp4, VideoCodec.av1),
];

/// Every case, in a stable order.
List<MatrixCase> matrixCases() {
  final cases = <MatrixCase>[];
  void add(ContainerFormat k, VideoCodec v, AudioKind a, [AudioCodec? c]) {
    for (final s in SourceClass.values) {
      if ((a == AudioKind.passthrough) && !k.copies(s.audioCodec)) continue;
      for (final t in MatrixTrim.values) {
        cases.add(MatrixCase(container: k, video: v, audio: a, audioCodec: c, source: s, trim: t));
      }
    }
  }

  for (final k in ContainerFormat.values) {
    final v = MatrixCase.defaultVideo(k);
    add(k, v, AudioKind.passthrough);
    for (final c in AudioCodec.values.where((c) => c.supportsContainer(k))) {
      add(k, v, AudioKind.convert, c);
    }
    add(k, v, AudioKind.restore);
    add(k, v, AudioKind.restoreConvert);
  }
  for (final (k, v) in extraVideoRows) {
    add(k, v, AudioKind.passthrough);
    add(k, v, AudioKind.restore);
  }
  return cases;
}

/// Cases that fail today, by id, with the task that owns the fault. They
/// still run, and fail if they pass, so the list can only shrink. Empty since
/// task #58 fixed what the matrix first found (docs/reports/
/// task-58-output-conformance-findings).
const knownFailures = <String, String>{};
