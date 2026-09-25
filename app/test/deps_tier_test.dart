import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/dependency_manager.dart';

/// The x86 deps bundles ship in two CPU tiers (issue #92): v3 for x86-64-v3
/// CPUs, v2 for anything older. These pin the rules that pick one, name its
/// release asset, and decide when an existing install is for the wrong CPU.
void main() {
  group('resolveTier', () {
    test('ARM platforms are not tiered, whatever the probe says', () {
      for (final id in ['macos-arm64', 'linux-arm64']) {
        expect(DependencyManager.resolveTier(platformId: id, probed: 'v3'), isNull);
        expect(DependencyManager.resolveTier(platformId: id, override: 'v2'), isNull);
      }
    });

    test('x86 follows the worker probe', () {
      for (final id in ['macos-x64', 'windows-x64', 'linux-x64']) {
        expect(DependencyManager.resolveTier(platformId: id, probed: 'v3'), 'v3');
        expect(DependencyManager.resolveTier(platformId: id, probed: 'v2'), 'v2');
      }
    });

    test('no clear answer on x86 means v2, which runs everywhere', () {
      // Guessing v3 wrongly is a crash on every job; v2 only costs speed.
      for (final probed in [null, '', 'v4', 'V3']) {
        expect(
            DependencyManager.resolveTier(platformId: 'macos-x64', probed: probed),
            'v2',
            reason: 'probe "$probed"');
      }
    });

    test('VAPOURBOX_DEPS_TIER overrides the probe in both directions', () {
      expect(
          DependencyManager.resolveTier(
              platformId: 'linux-x64', override: 'v2', probed: 'v3'),
          'v2');
      expect(
          DependencyManager.resolveTier(
              platformId: 'linux-x64', override: 'v3', probed: 'v2'),
          'v3');
    });

    test('an invalid override is ignored rather than trusted', () {
      expect(
          DependencyManager.resolveTier(
              platformId: 'linux-x64', override: 'fast', probed: 'v3'),
          'v3');
    });
  });

  group('release assets', () {
    test('v3 keeps the pre-tiering asset name; v2 is suffixed', () {
      expect(DependencyManager.assetIdFor('macos-x64', 'v3'), 'macos-x64');
      expect(DependencyManager.assetIdFor('macos-x64', 'v2'), 'macos-x64-v2');
      expect(DependencyManager.assetIdFor('macos-arm64', null), 'macos-arm64');
    });

    test('the v2 asset resolves to its own zip and sidecar', () {
      // Must agree with what the package-deps-* scripts upload.
      final info = DepsVersionInfo.fromJson({
        'version': '1.11.0',
        'releaseTag': 'deps-v1.11.0',
        'githubRepo': 'StuartCameronCode/VapourBox',
      });
      final id = DependencyManager.assetIdFor('windows-x64', 'v2');
      expect(info.filenameFor(id), 'VapourBox-deps-1.11.0-windows-x64-v2.zip');
      expect(
          info.getManifestUrl(id),
          'https://github.com/StuartCameronCode/VapourBox/releases/download/'
          'deps-v1.11.0/VapourBox-deps-1.11.0-windows-x64-v2.zip.sha256.json');
    });
  });

  group('tierMatches', () {
    test('a pre-tiering install is the v3 bundle', () {
      // Every x86 install before tiering is the v3 build — which is exactly
      // what faults on the #92 Mac Pro, so it must read as the wrong tier there.
      expect(DependencyManager.tierMatches(installed: null, machine: 'v3'), isTrue);
      expect(DependencyManager.tierMatches(installed: null, machine: 'v2'), isFalse);
    });

    test('a recorded tier must equal the machine tier', () {
      expect(DependencyManager.tierMatches(installed: 'v2', machine: 'v2'), isTrue);
      expect(DependencyManager.tierMatches(installed: 'v3', machine: 'v3'), isTrue);
      expect(DependencyManager.tierMatches(installed: 'v2', machine: 'v3'), isFalse);
      expect(DependencyManager.tierMatches(installed: 'v3', machine: 'v2'), isFalse);
    });

    test('ARM installs never mismatch', () {
      expect(DependencyManager.tierMatches(installed: null, machine: null), isTrue);
    });
  });

  group('version.json', () {
    test('round-trips the tier', () {
      final info = InstalledDepsInfo(version: '1.11.0', tier: 'v2');
      final back = InstalledDepsInfo.fromJson(info.toJson());
      expect(back.tier, 'v2');
      expect(back.version, '1.11.0');
    });

    test('omits the tier where there is none, and reads old files', () {
      expect(InstalledDepsInfo(version: '1.11.0').toJson().containsKey('tier'),
          isFalse);
      expect(InstalledDepsInfo.fromJson({'version': '1.10.0'}).tier, isNull);
    });
  });

  group('depsTier', () {
    final manager = DependencyManager.instance;
    tearDown(() {
      manager.tierProbeOverride = null;
      manager.resetTierForTesting();
    });

    test('asks the probe only where bundles are tiered, and caches it', () async {
      var calls = 0;
      manager.tierProbeOverride = () async {
        calls++;
        return 'v3';
      };
      final tiered = DependencyManager.isTiered(manager.platformId);
      final first = await manager.depsTier();
      final second = await manager.depsTier();
      expect(first, tiered ? 'v3' : isNull);
      expect(second, first);
      expect(calls, tiered ? 1 : 0);
    });
  });
}
