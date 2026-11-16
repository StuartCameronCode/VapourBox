/// The output conformance matrix's cases and oracle (task #49), checked
/// without encoding: `integration_output_conformance_test.dart` (heavy) runs
/// them.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/output_matrix.dart';

void main() {
  final cases = matrixCases();

  test('the count is the formula', () {
    var expected = 0;
    for (final k in ContainerFormat.values) {
      final rows = 1 + AudioCodec.values.where((c) => c.supportsContainer(k)).length + 2;
      final sources = SourceClass.values.length;
      final copied = SourceClass.values.where((s) => k.copies(s.audioCodec)).length;
      expected += ((rows - 1) * sources + copied) * MatrixTrim.everyCase.length;
    }
    for (final (k, _) in extraVideoRows) {
      final copied = SourceClass.values.where((s) => k.copies(s.audioCodec)).length;
      expected += (SourceClass.values.length + copied) * MatrixTrim.everyCase.length;
    }
    expected += tailCases.length;
    expect(cases, hasLength(expected));
    print('${cases.length} cases');
  });

  test('ids are unique and every enum value appears', () {
    expect(cases.map((c) => c.id).toSet(), hasLength(cases.length));
    expect(cases.map((c) => c.container).toSet(), ContainerFormat.values.toSet());
    expect(cases.map((c) => c.source).toSet(), SourceClass.values.toSet());
    expect(cases.map((c) => c.trim).toSet(), MatrixTrim.values.toSet());
    expect(cases.map((c) => c.audio).toSet(), AudioKind.values.toSet());
    expect(cases.where((c) => c.audio == AudioKind.convert).map((c) => c.audioCodec).toSet(),
        AudioCodec.values.toSet());
  });

  test('every case is a pair the table allows', () {
    for (final c in cases) {
      expect(c.video.supportsContainer(c.container), isTrue, reason: c.id);
      expect(c.convertCodec.supportsContainer(c.container), isTrue, reason: c.id);
      if (c.audio == AudioKind.passthrough) {
        expect(c.container.copies(c.source.audioCodec), isTrue, reason: c.id);
      }
      expect(c.container.copies(c.expectedAudioCodec), isTrue, reason: c.id);
    }
  });

  test('the tail trims are the primed Convert codecs into AVI (task #58)', () {
    final tail = cases.where((c) => c.trim == MatrixTrim.tail).toList();
    expect(tail.map((c) => c.id), [
      'avi/convert-aac/plain/tail',
      'avi/convert-libmp3lame/plain/tail',
      'avi/convert-ac3/plain/tail',
      'avi/restore-convert-aac/plain/tail',
    ]);
    expect(tail.first.expectedPictures, 50);
    expect(tail.first.trim.flashes, [55, 80]);
  });

  test('a restore of MP2 is checked against the float decode (task #58)', () {
    MatrixCase find(String id) => cases.singleWhere((c) => c.id == id);
    expect(find('mkv/restore/late-video/mid').referenceDecoder, 'mp2float');
    expect(find('mkv/convert-flac/late-video/mid').referenceDecoder, isNull);
    expect(find('mkv/restore/plain/mid').referenceDecoder, isNull);
  });

  test('every known failure names a real case', () {
    final ids = cases.map((c) => c.id).toSet();
    for (final id in knownFailures.keys) {
      expect(ids, contains(id));
    }
  });

  test('the oracle', () {
    MatrixCase find(String id) => cases.singleWhere((c) => c.id == id);
    final late = find('mkv/passthrough/late-video/untrimmed');
    expect(late.expectedPictures, 100);
    expect(late.expectedFirstPts(1.01), 1.01);
    expect(late.expectedFlashTimes(1.0), [1.2, 2.2, 3.2, 4.2]);
    final avi = find('avi/passthrough/late-video/untrimmed');
    expect(avi.expectedFirstPts(1.01), 0, reason: 'AVI starts both with the picture');
    final near = find('avi/convert-libmp3lame/delayed-avi/near-start');
    expect(near.expectedPictures, 50);
    expect(near.trim.flashes, [5, 30]);
    expect(near.expectedFlashTimes(0), [3 / 25, 28 / 25]);
    expect(find('mkv/passthrough/plain/mid').expectedFirstPts(0), isNull,
        reason: 'a trimmed copy keeps its pre-roll');
    expect(find('avi/passthrough/plain/mid').expectedFirstPts(0), 0);
    expect(find('mkv/restore/late-video/untrimmed').expectedFirstPts(1.01), 1.01);
    expect(find('mp4/restore/plain/mid').expectedAudioCodec, 'aac');
    expect(find('mp4/restore/plain/mid').lossless, LosslessCheck.none);
    expect(find('mkv/restore/plain/mid').lossless, LosslessCheck.exact);
    expect(find('avi/restore/plain/mid').expectedAudioCodec, 'pcm_s24le');
    expect(find('mov+proresProxy/restore/plain/mid').expectedAudioCodec, 'pcm_s24le');
    expect(find('mov/convert-pcm_s16le/reset-ps/mid').lossless, LosslessCheck.exact);
    expect(find('mp4/passthrough/plain/mid').lossless, LosslessCheck.copy);
    expect(find('avi/convert-aac/plain/mid').checksAacBlockAlign, isTrue);
    expect(find('avi/passthrough/plain/mid').checksAacBlockAlign, isTrue);
    expect(find('mkv/convert-aac/plain/mid').checksAacBlockAlign, isFalse);
    // ffprobe names MP2 in MP4 mp3 or mp2; only MP4 takes either.
    expect(find('mp4/passthrough/late-video/mid').audioCodecMatches('mp3'), isTrue);
    expect(find('mp4/passthrough/late-video/mid').audioCodecMatches('mp2'), isTrue);
    expect(find('mkv/passthrough/late-video/mid').audioCodecMatches('mp3'), isFalse);
  });
}
