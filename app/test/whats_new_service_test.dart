// Tests for the "NEW" badge version tracking: badges must persist across
// every launch of the same app version, and only advance the next time the
// app itself updates — not clear after a single run.
//
// Run with: flutter test test/whats_new_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/services/whats_new_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = WhatsNewService.instance;

  void setCurrentVersion(String version) {
    PackageInfo.setMockInitialValues(
      appName: 'VapourBox',
      packageName: 'app.vapourbox.vapourbox',
      version: version,
      buildNumber: '1',
      buildSignature: '',
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The singleton carries state between tests.
    service.resetForTesting();
  });

  group('WhatsNewService', () {
    test('fresh install flags nothing as new', () async {
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('0.1.0'), false);
      expect(service.isNew('1.2.0'), false);
    });

    test('an upgrade from a build that predates this tracking is treated like '
        'a fresh install', () async {
      // Old single-key data with no lastRunAppVersion at all — as if this
      // service shipped after the stored lastSeenAppVersion was written by
      // something else, or simply never existed before.
      SharedPreferences.setMockInitialValues({'lastSeenAppVersion': '1.1.0'});
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), false,
          reason: 'no lastRunAppVersion means there is nothing reliable to '
              'diff against yet, so this launch just seeds the baseline');
    });

    test('the first launch after an update flags anything shipped since the '
        'version being left behind', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), true, reason: 'added in the update just installed');
      expect(service.isNew('1.1.0'), false, reason: 'already present before this update');
      expect(service.isNew('1.0.0'), false, reason: 'shipped well before the update');
    });

    test('badges persist across many launches of the same version', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();
      expect(service.isNew('1.2.0'), true);

      // Close and reopen the app several times, still on 1.2.0 — nothing
      // about the installed version has changed, so the badge should keep
      // showing every time, not just the first.
      for (var i = 0; i < 3; i++) {
        service.resetForTesting();
        await service.initialize();
        expect(service.isNew('1.2.0'), true, reason: 'launch #${i + 2} at the same version');
      }
    });

    test('the next real update advances the baseline and clears the old badge',
        () async {
      // Already updated once (1.1.0 -> 1.2.0) and relaunched a few times.
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.2.0',
        'lastSeenAppVersion': '1.1.0',
      });

      // Now a second update lands: 1.2.0 -> 1.3.0.
      setCurrentVersion('1.3.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), false,
          reason: 'no longer new now that a further update has shipped');
      expect(service.isNew('1.3.0'), true, reason: 'added in the update just installed');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSeenAppVersion'), '1.2.0');
      expect(prefs.getString('lastRunAppVersion'), '1.3.0');
    });

    test('a patch release keeps the previous feature release\'s badges',
        () async {
      // 1.4.2 -> 1.5.0 set the baseline to 1.4.2; now 1.5.1 ships a fix.
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.5.0',
        'lastSeenAppVersion': '1.4.2',
      });
      setCurrentVersion('1.5.1');
      await service.initialize();

      expect(service.isNew('1.5.0'), true,
          reason: 'a bugfix release must not clear what 1.5.0 added');
      expect(service.isNew('1.5.1'), true, reason: 'anything the fix itself added');
      expect(service.isNew('1.4.2'), false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSeenAppVersion'), '1.4.2');
      expect(prefs.getString('lastRunAppVersion'), '1.5.1');
    });

    test('several patch releases in a row keep the same baseline', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.5.0',
        'lastSeenAppVersion': '1.4.2',
      });
      for (final version in ['1.5.1', '1.5.2', '1.5.10']) {
        service.resetForTesting();
        setCurrentVersion(version);
        await service.initialize();
        expect(service.isNew('1.5.0'), true, reason: 'still new on $version');
      }
    });

    test('the next feature release after patches advances past all of them',
        () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.5.2',
        'lastSeenAppVersion': '1.4.2',
      });
      setCurrentVersion('1.6.0');
      await service.initialize();

      expect(service.isNew('1.5.0'), false);
      expect(service.isNew('1.5.2'), false);
      expect(service.isNew('1.6.0'), true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSeenAppVersion'), '1.5.2');
    });

    test('a major release with the same minor number still advances', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.5.1',
        'lastSeenAppVersion': '1.4.0',
      });
      setCurrentVersion('2.5.0');
      await service.initialize();

      expect(service.isNew('1.5.0'), false);
      expect(service.isNew('2.5.0'), true);
    });

    test('jumping straight to a patch of a new feature release still badges it',
        () async {
      // Skipped 1.5.0 entirely: 1.4.2 -> 1.5.1 crosses a minor boundary.
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.4.2',
        'lastSeenAppVersion': '1.3.0',
      });
      setCurrentVersion('1.5.1');
      await service.initialize();

      expect(service.isNew('1.5.0'), true);
      expect(service.isNew('1.4.2'), false);
    });

    test('untagged (null) is never new', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew(null), false);
    });

    test('handles a version bump across a multi-digit component', () async {
      // Plain string comparison would put "1.10.0" before "1.9.0".
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.9.0',
        'lastSeenAppVersion': '1.9.0',
      });
      setCurrentVersion('1.10.0');
      await service.initialize();

      expect(service.isNew('1.10.0'), true);
    });
  });

  group('isSchemaNew (the pass row badge)', () {
    FilterSchema schema({String? since, Map<String, ParameterDefinition>? params}) =>
        FilterSchema(
          id: 'x',
          version: '1.0.0',
          name: 'X',
          sinceAppVersion: since,
          methods: const [],
          parameters: params ?? const {},
        );

    ParameterDefinition param(String? since, {bool hidden = false}) =>
        ParameterDefinition(
          type: ParameterType.number,
          defaultValue: 0,
          sinceAppVersion: since,
          ui: ParameterUiConfig(hidden: hidden),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();
    });

    test('a new filter is new', () {
      expect(service.isSchemaNew(schema(since: '1.2.0')), true);
    });

    test('a new parameter propagates up to its filter row', () {
      expect(
          service.isSchemaNew(schema(
              since: '1.0.0',
              params: {'old': param('1.0.0'), 'fresh': param('1.2.0')})),
          true);
    });

    test('nothing new means no badge', () {
      expect(service.isSchemaNew(schema(params: {'old': param('1.1.0')})), false);
      expect(service.isSchemaNew(null), false);
    });

    test('a hidden parameter has no control to find, so it does not count', () {
      expect(
          service.isSchemaNew(schema(params: {'h': param('1.2.0', hidden: true)})),
          false);
    });
  });

  // The rule everywhere: something new is badged, and so is every control on
  // the way to it — a new option's dropdown, a new method's Method label, a
  // switch that reveals a new control, a section holding one, the pass row.
  group('badges lead to what is new', () {
    ParameterDefinition p({String? since, Map<String, String>? options,
            Map<String, dynamic>? visibleWhen, bool hidden = false}) =>
        ParameterDefinition(
          type: options != null ? ParameterType.enumType : ParameterType.boolean,
          defaultValue: null,
          options: options?.keys.toList(),
          sinceAppVersion: since,
          optionSinceAppVersion: options == null
              ? null
              : {for (final e in options.entries) if (e.value.isNotEmpty) e.key: e.value},
          ui: ParameterUiConfig(visibleWhen: visibleWhen, hidden: hidden),
        );
    MethodDefinition m(String id, [String? since]) => MethodDefinition(
        id: id, name: id, function: 'f', parameters: const [], sinceAppVersion: since);
    FilterSchema schema(Map<String, ParameterDefinition> params,
            {List<MethodDefinition> methods = const []}) =>
        FilterSchema(id: 'x', version: '1.0.0', name: 'X', methods: methods, parameters: params);

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();
    });

    test('a new option badges itself and its dropdown, not its siblings', () {
      final method = p(options: {'old': '', 'fresh': '1.2.0'});
      final s = schema({'upscaleMethod': method});
      expect(service.isOptionNew(method, 'fresh'), isTrue);
      expect(service.isOptionNew(method, 'old'), isFalse);
      expect(service.isParameterNew(s, 'upscaleMethod'), isTrue);
      expect(service.isSchemaNew(s), isTrue);
    });

    test('a switch badges for what it reveals, through every level', () {
      // Enable Upscale -> Upscale Method (new option) -> a setting only that
      // option shows; and a sibling switch revealing nothing new stays plain.
      final s = schema({
        'enable': p(),
        'method': p(options: {'old': '', 'fresh': '1.2.0'}, visibleWhen: {'enable': true}),
        'freshOnly': p(visibleWhen: {'method': ['fresh']}),
        'other': p(),
        'otherChild': p(visibleWhen: {'other': true}),
      });
      expect(service.isParameterNew(s, 'enable'), isTrue);
      expect(service.isParameterNew(s, 'other'), isFalse);
      // Revealed by a new control, but new only through a level below.
      final deep = schema({
        'a': p(),
        'b': p(visibleWhen: {'a': true}),
        'c': p(since: '1.2.0', visibleWhen: {'b': true}),
      });
      expect(service.isParameterNew(deep, 'a'), isTrue);
    });

    test('a hidden control reveals nothing and a cycle cannot recurse forever', () {
      final s = schema({
        'a': p(visibleWhen: {'b': true}),
        'b': p(visibleWhen: {'a': true}),
        'h': p(since: '1.2.0', hidden: true, visibleWhen: {'a': true}),
      });
      expect(service.isParameterNew(s, 'a'), isFalse);
    });

    test('a new method badges the method list and the pass row', () {
      final s = schema({}, methods: [m('old'), m('fresh', '1.2.0')]);
      expect(service.isMethodNew(s.methods[1]), isTrue);
      expect(service.isMethodNew(s.methods[0]), isFalse);
      expect(service.isMethodChoiceNew(s), isTrue);
      expect(service.isSchemaNew(s), isTrue);
      // A new control that only some methods show badges the list too.
      final gated = schema({'x': p(since: '1.2.0', visibleWhen: {'method': ['old']})},
          methods: [m('old'), m('older')]);
      expect(service.isMethodChoiceNew(gated), isTrue);
    });

    test('a section badges when anything in it does', () {
      final s = schema({'enable': p(), 'child': p(since: '1.2.0', visibleWhen: {'enable': true}), 'plain': p()});
      expect(service.isSectionNew(s, const UiSection(title: 'A', parameters: ['enable'])), isTrue);
      expect(service.isSectionNew(s, const UiSection(title: 'B', parameters: ['plain'])), isFalse);
    });

    test('nothing badges once the update is no longer the latest', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.2.0',
        'lastSeenAppVersion': '1.2.0',
      });
      service.resetForTesting();
      await service.initialize();
      final s = schema({
        'enable': p(),
        'method': p(options: {'fresh': '1.2.0'}, visibleWhen: {'enable': true}),
      }, methods: [m('a'), m('b', '1.2.0')]);
      expect(service.isParameterNew(s, 'enable'), isFalse);
      expect(service.isSchemaNew(s), isFalse);
    });
  });
}
