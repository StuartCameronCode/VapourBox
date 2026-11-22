import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether the deps bundle at [depsDir] is older than [version], pre-releases
/// included (`1.18.0-rc1` < `1.18.0-rc2` < `1.18.0`). A missing or unreadable
/// file counts as newer, so the check it guards still runs.
///
/// `DependencyManager.compareVersions` is not this: it reads `0-rc3` as 0, so
/// it cannot tell release candidates apart.
bool depsVersionBefore(String depsDir, String version) {
  (List<int>, int) parse(String v) {
    final dash = v.indexOf('-');
    final core = (dash < 0 ? v : v.substring(0, dash)).split('.').map(int.parse).toList();
    final rc = dash < 0
        ? 1 << 30 // a release sorts after all its candidates
        : int.parse(RegExp(r'(\d+)$').firstMatch(v.substring(dash))!.group(1)!);
    return (core, rc);
  }

  try {
    final json = jsonDecode(File(p.join(depsDir, 'version.json')).readAsStringSync())
        as Map<String, dynamic>;
    final (have, haveRc) = parse(json['version'] as String);
    final (want, wantRc) = parse(version);
    for (var i = 0; i < want.length; i++) {
      final v = i < have.length ? have[i] : 0;
      if (v != want[i]) return v < want[i];
    }
    return haveRc < wantRc;
  } catch (_) {
    return false;
  }
}
