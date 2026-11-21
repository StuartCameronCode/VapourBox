import 'package:vapourbox/services/timestamp_continuity_service.dart';

/// A continuity service whose `--probe-source` answers neither a model nor
/// an error ([SourceProbe.none]), for queue tests that put files that don't
/// exist in the queue and set their status by hand. Without it the app's own
/// service reports "the worker could not be found" and fails each item
/// (task #85), which is what a user would see but not what those tests are
/// about.
class NoSourceModelContinuity extends TimestampContinuityService {
  const NoSourceModelContinuity();

  @override
  Future<SourceProbe> probeSource(String path, {bool deferScan = false}) async =>
      SourceProbe.none;
}
