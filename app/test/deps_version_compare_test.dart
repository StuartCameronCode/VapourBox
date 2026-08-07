/// The version comparison decides whether the app REPLACES an installed deps
/// bundle, and installing wipes the existing one. Getting the direction or the
/// ordering wrong is therefore destructive, not cosmetic:
///
///   - a plain string compare puts "1.10.0" before "1.9.0", so a newer bundle
///     reads as older and gets downgraded;
///   - treating "newer" as "outdated" downgrades a deliberately newer bundle,
///     which is how a locally built tree got replaced by the published one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/dependency_manager.dart';

void main() {
  int cmp(String a, String b) => DependencyManager.compareVersions(a, b);

  group('compareVersions', () {
    test('equal versions compare equal', () {
      expect(cmp('1.7.0', '1.7.0'), 0);
    });

    test('orders numerically, not lexically', () {
      // The case a string compare gets wrong.
      expect(cmp('1.10.0', '1.9.0'), greaterThan(0));
      expect(cmp('1.9.0', '1.10.0'), lessThan(0));
      expect(cmp('2.0.0', '10.0.0'), lessThan(0));
    });

    test('orders across each component', () {
      expect(cmp('1.8.0', '1.7.0'), greaterThan(0));
      expect(cmp('1.7.1', '1.7.0'), greaterThan(0));
      expect(cmp('2.0.0', '1.99.99'), greaterThan(0));
    });

    test('missing components count as zero', () {
      expect(cmp('1.7', '1.7.0'), 0);
      expect(cmp('1.7.1', '1.7'), greaterThan(0));
    });

    test('unparseable components degrade instead of throwing', () {
      // An unreadable version must not crash startup.
      expect(() => cmp('1.x.0', '1.0.0'), returnsNormally);
      expect(cmp('', '1.0.0'), lessThan(0));
    });

    test('the R73 -> R78 upgrade direction is an upgrade, not a downgrade', () {
      expect(cmp('1.7.0', '1.8.0'), lessThan(0));
      expect(cmp('1.8.0', '1.7.0'), greaterThan(0));
    });
  });
}
