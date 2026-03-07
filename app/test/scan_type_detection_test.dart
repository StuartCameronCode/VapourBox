// Tests that verify scan type detection for different video sources.
// Uses real test videos in Tests/TestResources/ to ensure correct
// auto-selection of deinterlace method.
//
// Run with: flutter test test/scan_type_detection_test.dart

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/tool_locator.dart';

void main() {
  late String testResourcesDir;
  late FieldOrderDetector detector;

  setUpAll(() async {
    // Find test resources relative to the app/ directory
    final scriptDir = Directory.current.path;
    testResourcesDir = path.join(scriptDir, '..', 'Tests', 'TestResources');

    if (!await Directory(testResourcesDir).exists()) {
      fail('Test resources directory not found: $testResourcesDir');
    }

    // Initialize ToolLocator so ffmpeg/ffprobe are available
    await ToolLocator.instance.initialize();
    if (ToolLocator.instance.ffmpegPath == null) {
      fail('ffmpeg not found — ensure deps are downloaded');
    }
    if (ToolLocator.instance.ffprobePath == null) {
      fail('ffprobe not found — ensure deps are downloaded');
    }

    detector = FieldOrderDetector();
  });

  group('Scan Type Detection', () {
    test('soft_telecine_test.mkv is detected as soft telecine', () async {
      final videoPath = path.join(testResourcesDir, 'soft_telecine_test.mkv');
      if (!await File(videoPath).exists()) {
        markTestSkipped('soft_telecine_test.mkv not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      expect(info!.scanType, ScanType.softTelecine,
          reason: 'idet sees progressive frames but repeat_pict reveals '
              'soft telecine pulldown flags');
    });

    test('hard_telecine_test.avi is detected as hard telecine', () async {
      final videoPath = path.join(testResourcesDir, 'hard_telecine_test.avi');
      if (!await File(videoPath).exists()) {
        markTestSkipped('hard_telecine_test.avi not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      // idet detects interlaced frames with repeated fields → hard telecine
      expect(info!.scanType, ScanType.telecine,
          reason: 'idet shows TFF interlaced frames with repeated fields '
              '— hard telecine requiring IVTC');
    });

    test('interlaced_test.avi is detected as interlaced', () async {
      final videoPath = path.join(testResourcesDir, 'interlaced_test.avi');
      if (!await File(videoPath).exists()) {
        markTestSkipped('interlaced_test.avi not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      // idet detects TFF interlaced frames, no repeated fields
      expect(info!.scanType, ScanType.interlaced,
          reason: 'idet shows TFF interlaced frames without repeated fields '
              '— standard interlaced content');
    });

    test('telecine_test_processed.mkv is detected as progressive', () async {
      final videoPath =
          path.join(testResourcesDir, 'telecine_test_processed.mkv');
      if (!await File(videoPath).exists()) {
        markTestSkipped('telecine_test_processed.mkv not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      // H.264 progressive at 23.976fps — already processed, no telecine
      expect(info!.scanType, ScanType.progressive,
          reason: 'H.264 progressive at 23.976fps '
              'should be detected as progressive');
    });

    test('interlaced_test_deinterlaced.mp4 is detected as progressive',
        () async {
      final videoPath =
          path.join(testResourcesDir, 'interlaced_test_deinterlaced.mp4');
      if (!await File(videoPath).exists()) {
        markTestSkipped('interlaced_test_deinterlaced.mp4 not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      // idet sees 100% progressive frames
      expect(info!.scanType, ScanType.progressive,
          reason: 'idet shows all progressive frames '
              '— deinterlaced output');
    });

    test('interlaced_test_deinterlaced.avi is detected as progressive',
        () async {
      final videoPath =
          path.join(testResourcesDir, 'interlaced_test_deinterlaced.avi');
      if (!await File(videoPath).exists()) {
        markTestSkipped('interlaced_test_deinterlaced.avi not found');
        return;
      }

      final info = await detector.getVideoInfo(videoPath);
      expect(info, isNotNull);
      // idet sees ~97% progressive frames (a few TFF false positives)
      expect(info!.scanType, ScanType.progressive,
          reason: 'idet shows overwhelmingly progressive frames '
              '— deinterlaced FFV1 output');
    });
  });
}
