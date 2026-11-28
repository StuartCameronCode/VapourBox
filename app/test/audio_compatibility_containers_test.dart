// Task #132: the Passthrough audio dialog's "Change container format" offers
// only containers that take a copy of the sound AND are offered for the job's
// video codec, and its "save as" text names the same ones. Before, it offered
// every container that copied the sound, so AV1 could be switched into MOV or
// AVI and v210 / ProRes into MP4, pairs the worker refuses.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/audio_compatibility_service.dart';
import 'package:vapourbox/views/audio_compatibility_dialog.dart';

/// The dialog is laid out for a desktop window; the default 800x600 test
/// view overflows it.
void _desktopView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  final copyCodecs = [
    ...(AudioCompatibilityService.knownCodecs.toList()..sort()),
    'wmav2', // copied by no container
  ];

  test('the offered containers hold both the sound and the video codec', () {
    for (final video in VideoCodec.values) {
      for (final audio in copyCodecs) {
        final offered =
            AudioCompatibilityService.compatibleContainers(audio, video);
        expect(
          offered,
          ContainerFormat.values
              .where((k) => k.copies(audio) && video.supportsContainer(k))
              .toList(),
          reason: '${video.name} + $audio',
        );
        for (final k in offered) {
          expect(video.containerVerdict(k), ContainerVerdict.offered,
              reason: '${video.name} + $audio offered ${k.shortName}');
        }
      }
    }
  });

  test('every result the dialog can get offers only valid pairs', () {
    for (final video in VideoCodec.values) {
      for (final audio in copyCodecs) {
        for (final container in ContainerFormat.values) {
          final r = AudioCompatibilityService.resultFor(
            audioInfo: AudioInfo(codec: audio),
            outputContainer: container,
            audioMode: AudioMode.passthrough,
            videoCodec: video,
          );
          expect(r.isCompatible, container.copies(audio));
          for (final k in r.compatibleContainers) {
            expect(video.containerVerdict(k), isNot(ContainerVerdict.refused),
                reason: '${video.name} + $audio from ${container.shortName}');
            expect(video.supportsContainer(k), isTrue);
          }
          // The text names no container the chips leave out.
          final reason = r.incompatibilityReason;
          if (reason == null) continue;
          final saveAs = reason.split(', or save as ');
          if (saveAs.length < 2) continue;
          for (final k in ContainerFormat.values) {
            if (RegExp('\\b${k.shortName}\\b').hasMatch(saveAs[1])) {
              expect(r.compatibleContainers, contains(k),
                  reason: '${video.name} + $audio: $reason');
            }
          }
        }
      }
    }
  });

  test('the named cases from the table', () {
    expect(AudioCompatibilityService.compatibleContainers('pcm_u8', VideoCodec.av1),
        [ContainerFormat.mkv]);
    expect(AudioCompatibilityService.compatibleContainers('opus', VideoCodec.v210),
        [ContainerFormat.mkv]);
    expect(AudioCompatibilityService.compatibleContainers('pcm_u8', VideoCodec.h264),
        [ContainerFormat.mov, ContainerFormat.mkv, ContainerFormat.avi]);
    // Only MKV copies WavPack, and ProRes is offered only in MOV.
    expect(
        AudioCompatibilityService.compatibleContainers('wavpack', VideoCodec.prores422),
        isEmpty);
  });

  test('the copy refusal names only containers the video codec is offered in', () {
    expect(
        AudioCompatibilityService.copyProblem('pcm_u8', ContainerFormat.mp4,
            videoCodec: VideoCodec.av1),
        'PCM_U8 audio can\'t be copied into MP4 files. Choose Convert in '
        'Settings → Audio, or save as MKV.');
    expect(
        AudioCompatibilityService.copyProblem('opus', ContainerFormat.avi,
            videoCodec: VideoCodec.v210),
        'OPUS audio can\'t be copied into AVI files. Choose Convert in '
        'Settings → Audio, or save as MKV.');
    // Nowhere to go: the "save as" clause is dropped, as for a codec no
    // container copies.
    expect(
        AudioCompatibilityService.copyProblem('wavpack', ContainerFormat.mov,
            videoCodec: VideoCodec.prores422),
        'WAVPACK audio can\'t be copied into MOV files. Choose Convert in '
        'Settings → Audio.');
    // Without a video codec the words are unchanged (the worker's `None`).
    expect(
        AudioCompatibilityService.copyProblem('pcm_u8', ContainerFormat.mp4),
        'PCM_U8 audio can\'t be copied into MP4 files. Choose Convert in '
        'Settings → Audio, or save as MOV, MKV or AVI.');
  });

  testWidgets('the dialog offers AV1 only MKV for PCM_U8 sound',
      (tester) async {
    _desktopView(tester);
    final compatibility = AudioCompatibilityService.resultFor(
      audioInfo: const AudioInfo(codec: 'pcm_u8'),
      outputContainer: ContainerFormat.mp4,
      audioMode: AudioMode.passthrough,
      videoCodec: VideoCodec.av1,
    );
    AudioCompatibilityDialogResult? popped;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped = await AudioCompatibilityDialog.show(
                context: context, compatibility: compatibility);
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .map((c) => (c.label as Text).data)
        .toList();
    expect(chips, [ContainerFormat.mkv.displayName]);
    expect(find.textContaining('or save as MKV.'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, ContainerFormat.mkv.displayName));
    await tester.pumpAndSettle();
    expect(popped?.choice, AudioCompatibilityChoice.changeContainer);
    expect(popped?.newContainer, ContainerFormat.mkv);
  });

  testWidgets('no container option when none holds both', (tester) async {
    _desktopView(tester);
    final compatibility = AudioCompatibilityService.resultFor(
      audioInfo: const AudioInfo(codec: 'wavpack'),
      outputContainer: ContainerFormat.mov,
      audioMode: AudioMode.passthrough,
      videoCodec: VideoCodec.prores422,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AudioCompatibilityDialog(compatibility: compatibility)),
    ));
    expect(find.text('Change container format'), findsNothing);
    expect(find.text('Re-encode audio'), findsOneWidget);
  });
}
