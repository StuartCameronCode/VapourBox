import 'package:vapourbox/services/system_shutdown.dart';

/// A [SystemShutdown] that never shuts anything down — it only counts.
class FakeSystemShutdown implements SystemShutdown {
  /// What [check] reports; null means the shutdown would go through.
  String? checkProblem;

  /// What [shutDown] reports; null means the OS accepted the request.
  String? shutDownProblem;

  int checkCount = 0;
  int shutDownCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<String?> check() async {
    checkCount++;
    return checkProblem;
  }

  @override
  Future<String?> shutDown() async {
    shutDownCount++;
    return shutDownProblem;
  }
}
