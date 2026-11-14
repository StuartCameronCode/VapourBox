// Task #21: a TS/PS whose timestamps reset is decoded from a joined copy.
// The view model asks the continuity service when it analyses a video and,
// given a copy, sends that copy (with continuityChecked) to every worker job,
// while the user's file still names the output. The service is faked: the
// real one runs the worker (integration_seek_alignment_test, heavy).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/crop_detect_report.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';

class _FakeContinuity extends TimestampContinuityService {
  final ContinuityProxy? proxy;
  final bool checked;
  final String? error;
  final asked = <String>[];
  _FakeContinuity({this.proxy, this.checked = true, this.error});

  @override
  Future<({bool checked, ContinuityProxy? proxy, ContinuityScan? scan, String? error})>
      prepare(String source, String id,
          {void Function(ContinuityScan)? onJoining,
          void Function(double)? onProgress}) async {
    asked.add(source);
    return (checked: checked, proxy: proxy, scan: null, error: error);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<VideoJob> detectorJobs;

  MainViewModel vmWith(_FakeContinuity c) => MainViewModel(
        runner: FakeJobRunner(),
        continuityService: c,
        cropDetector: (job) async {
          detectorJobs.add(job);
          return const CropDetectReport.failed('fake');
        },
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    detectorJobs = [];
  });

  test('a source with a reset is decoded from its joined copy', () async {
    const proxy = ContinuityProxy(
        path: '/tmp/continuous_abc_show.vob', resetCount: 3, sizeBytes: 1 << 20);
    final c = _FakeContinuity(proxy: proxy);
    final vm = vmWith(c);
    await vm.addToQueue('/videos/show.vob');
    final item = vm.selectedItem!;

    expect(c.asked, ['/videos/show.vob'], reason: 'the user\'s file is scanned');
    expect(item.continuityProxy, same(proxy));
    expect(item.decodePath, proxy.path);
    expect(item.inputPath, '/videos/show.vob');
    expect(item.outputPath, isNot(contains('continuous_')),
        reason: 'the output is named after the user\'s file');
    expect(vm.logMessages.map((m) => m.message).join('\n'),
        contains('Timestamps reset 3 times'));

    await vm.detectCrop();
    expect(detectorJobs.single.inputPath, proxy.path);
    expect(detectorJobs.single.continuityChecked, isTrue);
    expect(detectorJobs.single.toJson()['continuityChecked'], isTrue);
    vm.dispose();
  });

  test('a source without one is decoded as it is, and says it was checked', () async {
    final c = _FakeContinuity();
    final vm = vmWith(c);
    await vm.addToQueue('/videos/film.mpg');
    expect(vm.selectedItem!.decodePath, '/videos/film.mpg');
    await vm.detectCrop();
    expect(detectorJobs.single.inputPath, '/videos/film.mpg');
    expect(detectorJobs.single.continuityChecked, isTrue);
    vm.dispose();
  });

  test('a failed copy keeps the source, warns, and leaves the worker to warn too', () async {
    final c = _FakeContinuity(checked: false, error: 'disk full');
    final vm = vmWith(c);
    await vm.addToQueue('/videos/capture.ts');
    expect(vm.selectedItem!.decodePath, '/videos/capture.ts');
    expect(vm.logMessages.map((m) => m.message).join('\n'), contains('disk full'));
    await vm.detectCrop();
    expect(detectorJobs.single.continuityChecked, isFalse);
    vm.dispose();
  });
}
