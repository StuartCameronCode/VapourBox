import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'addon_manager.dart';
import 'addon_service.dart';

/// Add-ons described entirely by a manifest, one JSON file per add-on in
/// `assets/addons/` (format: docs/ADDONS.md). The worker compiles in the same
/// files (`worker/src/addons.rs`), so the app and the worker agree on what
/// each add-on is, where it installs and what "installed" means.
///
/// Two kinds:
/// * `files` — a model pack: each file is downloaded into `addons/<id>/`,
///   or, for an archive entry, only its listed members are kept, each checked
///   against its own hash.
/// * `python` — Python packages for VapourBox's own Python: each file is a
///   wheel, unpacked into `addons/<id>/site-packages/`.
///
/// Everything is pinned by SHA-256; an install is built in `addons/<id>.new`
/// and renamed into place, and ends by writing [markerName], so neither the
/// app nor the worker ever sees a partial install. A manifest whose `version`
/// changes makes the installed copy count as missing, so the feature asks for
/// it again and the install replaces it.

/// The platform ids the add-ons are described for (the deps bundle's).
const addonPlatformIds = [
  'macos-arm64',
  'macos-x64',
  'windows-x64',
  'linux-x64',
  'linux-arm64',
];

/// `VAPOURBOX_ADDON_MIRROR=DIR`: take each file from `DIR/` + the last path
/// segment of its url instead of downloading it, still checked against its
/// size and hash — for testing an add-on whose files are not uploaded yet.
/// A file the mirror doesn't hold is downloaded as usual, so a mirror of our
/// own converted files still installs add-ons whose files come from upstream
/// (the AI runtime's wheels).
const addonMirrorEnv = 'VAPOURBOX_ADDON_MIRROR';

/// One file a manifest add-on installs.
class AddonManifestFile {
  /// Its name in `addons/<id>/` (a `files` add-on), or the wheel's file name.
  final String name;
  final String url;
  final int size;
  final String sha256;

  /// The platforms it is for; null means every platform the add-on supports.
  final List<String>? platforms;

  /// For an archive: the members to keep (nothing else is extracted). Null
  /// for a file kept as downloaded, or a wheel.
  final List<AddonArchiveMember>? extract;

  /// A program the worker runs (DeepFilterNet's `deep-filter`): installed
  /// with its executable bit set and, on macOS, signed if it is not.
  final bool executable;

  const AddonManifestFile({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    this.platforms,
    this.extract,
    this.executable = false,
  });

  factory AddonManifestFile.fromJson(Map<String, dynamic> json) => AddonManifestFile(
        name: json['name'] as String,
        url: json['url'] as String,
        size: json['size'] as int,
        sha256: json['sha256'] as String,
        platforms: (json['platforms'] as List<dynamic>?)?.cast<String>(),
        extract: (json['extract'] as List<dynamic>?)
            ?.map((m) => AddonArchiveMember.fromJson((m as Map).cast<String, dynamic>()))
            .toList(),
        executable: json['executable'] as bool? ?? false,
      );

  bool isFor(String platformId) => platforms == null || platforms!.contains(platformId);
}

/// A member of an archive entry: its path inside the archive, the name it is
/// installed under, and its own hash.
class AddonArchiveMember {
  final String path;
  final String name;
  final String sha256;

  const AddonArchiveMember({required this.path, required this.name, required this.sha256});

  factory AddonArchiveMember.fromJson(Map<String, dynamic> json) => AddonArchiveMember(
        path: json['path'] as String,
        name: json['name'] as String? ?? (json['path'] as String).split('/').last,
        sha256: json['sha256'] as String,
      );
}

/// One add-on's manifest (`assets/addons/<id>.json`).
class AddonManifest {
  final String id;
  final String version;
  final String name;
  final String feature;
  final String description;
  final String licence;
  final String? licenceUrl;
  final String? usageNote;
  final String credit;
  final String noticeName;
  final String homepage;
  final List<String> requires;

  /// `files` or `python`.
  final String kind;

  /// Platform id → its requirements (`minOs`, macOS only), for the platforms
  /// it supports. `"platforms": "all"` in the file is every [addonPlatformIds].
  final Map<String, Map<String, dynamic>> platforms;
  final List<AddonManifestFile> files;

  /// Further components credited separately, each with optional `platforms`.
  final List<Map<String, dynamic>> components;

  const AddonManifest({
    required this.id,
    required this.version,
    required this.name,
    required this.feature,
    required this.description,
    required this.licence,
    this.licenceUrl,
    this.usageNote,
    required this.credit,
    required this.noticeName,
    required this.homepage,
    this.requires = const [],
    required this.kind,
    required this.platforms,
    required this.files,
    this.components = const [],
  });

  static const kinds = {'files', 'python'};

  /// Parse and validate: a malformed manifest fails here, in the test suite,
  /// rather than as a half-working add-on.
  factory AddonManifest.fromJson(Map<String, dynamic> json) {
    final rawPlatforms = json['platforms'];
    final platforms = rawPlatforms == 'all'
        ? {for (final p in addonPlatformIds) p: <String, dynamic>{}}
        : {
            for (final MapEntry(:key, :value) in (rawPlatforms as Map).entries)
              key as String: (value as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
          };
    final m = AddonManifest(
      id: json['id'] as String,
      version: json['version'] as String,
      name: json['name'] as String,
      feature: json['feature'] as String,
      description: json['description'] as String,
      licence: json['licence'] as String,
      licenceUrl: json['licenceUrl'] as String?,
      usageNote: json['usageNote'] as String?,
      credit: json['credit'] as String,
      noticeName: json['noticeName'] as String,
      homepage: json['homepage'] as String,
      requires: (json['requires'] as List<dynamic>? ?? []).cast<String>(),
      kind: json['kind'] as String,
      platforms: platforms,
      files: (json['files'] as List<dynamic>)
          .map((f) => AddonManifestFile.fromJson((f as Map).cast<String, dynamic>()))
          .toList(),
      components: [
        for (final c in json['components'] as List<dynamic>? ?? []) (c as Map).cast<String, dynamic>(),
      ],
    );
    m._validate();
    return m;
  }

  void _validate() {
    void fail(String why) => throw FormatException('Add-on manifest "$id": $why');
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id)) fail('id must be lower-case-with-dashes');
    if (!kinds.contains(kind)) fail('kind must be one of $kinds');
    for (final p in platforms.keys) {
      if (!addonPlatformIds.contains(p)) fail('unknown platform $p');
    }
    final hash = RegExp(r'^[0-9a-f]{64}$');
    final names = <String>{};
    for (final f in files) {
      if (!hash.hasMatch(f.sha256)) fail('${f.name} needs a lower-case hex sha256');
      if (f.size <= 0) fail('${f.name} needs its size');
      if (!f.url.startsWith('https://')) fail('${f.name} must download over https');
      if (!_safeName(f.name)) fail('${f.name} is not a plain file name');
      if (!names.add(f.name)) fail('${f.name} is listed twice');
      for (final p in f.platforms ?? const <String>[]) {
        if (!platforms.containsKey(p)) fail('${f.name} names $p, which the add-on does not support');
      }
      if (kind == 'python' && (!f.name.endsWith('.whl') || f.extract != null)) {
        fail('a python add-on lists only wheels (${f.name})');
      }
      if (f.executable && (kind != 'files' || f.extract != null)) {
        fail('only a plain file of a files add-on can be executable (${f.name})');
      }
      for (final member in f.extract ?? const <AddonArchiveMember>[]) {
        if (!hash.hasMatch(member.sha256)) fail('${member.path} needs a sha256');
        if (!_safeName(member.name)) fail('${member.name} is not a plain file name');
      }
    }
    for (final p in platforms.keys) {
      if (!files.any((f) => f.isFor(p))) fail('no files for $p');
    }
  }

  static bool _safeName(String name) =>
      name.isNotEmpty && !name.contains('/') && !name.contains('\\') && name != '.' && name != '..';

  /// The files this platform installs.
  List<AddonManifestFile> filesFor(String platformId) =>
      files.where((f) => f.isFor(platformId)).toList();

  /// Every manifest shipped in `assets/addons/`, found through the asset
  /// manifest so a new file needs no index to be picked up.
  static Future<List<AddonManifest>> loadBundled({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    final assets = (await AssetManifest.loadFromAssetBundle(b))
        .listAssets()
        .where((a) => a.startsWith('assets/addons/') && a.endsWith('.json'))
        .toList()
      ..sort();
    return [
      for (final a in assets)
        AddonManifest.fromJson(jsonDecode(await b.loadString(a)) as Map<String, dynamic>),
    ];
  }

  /// Every manifest in a directory on disk (tests, and the harness).
  static List<AddonManifest> loadDirectory(Directory dir) {
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in files)
        AddonManifest.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>),
    ];
  }
}

/// Installs, recognises and removes one manifest add-on (see the library
/// comment). Every file is verified before anything is unpacked.
class ManifestAddonInstaller implements AddonInstaller {
  final AddonManifest manifest;
  final String platformId;

  /// The running macOS version ("15.1"), for `minOs`; read from the system
  /// unless given (tests).
  final String? _osVersion;

  /// Where to take files from instead of the network; defaults to
  /// [addonMirrorEnv]. An empty string means no mirror whatever the
  /// environment says (the installer's own unit tests use it).
  final String? _mirror;

  ManifestAddonInstaller(this.manifest, this.platformId, {String? osVersion, String? mirror})
      : _osVersion = osVersion,
        _mirror = mirror;

  /// Written last into an install, as its commit marker: the add-on's id,
  /// version and platform. The worker reads the same file.
  static const markerName = '.vapourbox-addon.json';

  String? get mirror {
    if (_mirror != null) return _mirror.isEmpty ? null : _mirror;
    final env = Platform.environment[addonMirrorEnv];
    return env == null || env.isEmpty ? null : env;
  }

  List<AddonManifestFile> get _files => manifest.filesFor(platformId);

  @override
  AddonInfo get info => AddonInfo(
        id: manifest.id,
        name: manifest.name,
        feature: manifest.feature,
        description: manifest.description,
        licence: manifest.licence,
        licenceUrl: manifest.licenceUrl,
        usageNote: manifest.usageNote,
        credit: manifest.credit,
        noticeName: manifest.noticeName,
        sourceUrl: manifest.homepage,
        downloadBytes: _files.fold(0, (sum, f) => sum + f.size),
        requires: manifest.requires,
        unavailableReason: unavailableReason,
        additionalCredits: [
          for (final c in manifest.components)
            if ((c['platforms'] as List<dynamic>?)?.contains(platformId) ?? true)
              AddonCredit(
                noticeName: c['noticeName'] as String,
                licence: c['licence'] as String,
                licenceUrl: c['licenceUrl'] as String?,
                credit: c['credit'] as String,
                sourceUrl: c['homepage'] as String,
              ),
        ],
      );

  static const _platformNames = {
    'macos-arm64': 'Apple Silicon Macs',
    'macos-x64': 'Intel Macs',
    'windows-x64': 'Windows',
    'linux-x64': 'Linux (x64)',
    'linux-arm64': 'Linux on ARM',
  };

  /// Why it cannot be installed here, or null: the platform is not in the
  /// manifest's table, or (macOS) the system is older than its `minOs`.
  String? get unavailableReason {
    final requirements = manifest.platforms[platformId];
    if (requirements == null) {
      return '${manifest.name} isn\'t available for '
          '${_platformNames[platformId] ?? 'this platform'}.';
    }
    final minOs = requirements['minOs'] as String?;
    if (minOs != null && platformId.startsWith('macos')) {
      final running = _osVersion ?? macOsVersion();
      if (running != null && compareOsVersions(running, minOs) < 0) {
        return '${manifest.name} needs macOS $minOs or later; this Mac has $running.';
      }
    }
    return null;
  }

  /// The macOS version this is running on, or null elsewhere / unreadable.
  static String? macOsVersion() {
    if (!Platform.isMacOS) return null;
    return RegExp(r'\d+(\.\d+)*').firstMatch(Platform.operatingSystemVersion)?.group(0);
  }

  /// Compare dotted versions numerically ("13.0" < "13.10").
  static int compareOsVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  Directory target(Directory addonsDir) => Directory(path.join(addonsDir.path, manifest.id));

  /// The files a complete install of this platform's files holds, relative to
  /// the add-on's directory (a python add-on: its site-packages directory).
  List<String> get expectedPaths => manifest.kind == 'python'
      ? ['site-packages']
      : [
          for (final f in _files)
            if (f.extract == null) f.name else ...f.extract!.map((m) => m.name),
        ];

  @override
  bool isInstalled(Directory addonsDir) {
    final dir = target(addonsDir);
    final marker = File(path.join(dir.path, markerName));
    if (!marker.existsSync()) return false;
    try {
      final json = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      if (json['id'] != manifest.id ||
          json['version'] != manifest.version ||
          json['platform'] != platformId) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return expectedPaths.every((p) => FileSystemEntity.typeSync(path.join(dir.path, p)) !=
        FileSystemEntityType.notFound);
  }

  @override
  Future<void> install(Directory addonsDir, AddonManager downloader) async {
    final reason = unavailableReason;
    if (reason != null) throw StateError(reason);
    final dest = target(addonsDir);
    final staging = Directory('${dest.path}.new');
    final old = Directory('${dest.path}.old');
    // Downloads are kept beside the add-ons, not in temp, so a cancelled one
    // resumes (AddonManager keeps the .partial), and are removed once installed.
    final downloads =
        Directory(path.join(addonsDir.path, '.downloads', '${manifest.id}-${manifest.version}'));
    try {
      await downloads.create(recursive: true);
      final fetched = <AddonManifestFile, File>{};
      for (final f in _files) {
        final file = File(path.join(downloads.path, f.name));
        await _fetch(f, file, downloader);
        if (downloader.isCancelled) return;
        fetched[f] = file;
      }

      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      for (final MapEntry(key: f, value: file) in fetched.entries) {
        if (manifest.kind == 'python') {
          await extractWheel(file, Directory(path.join(staging.path, 'site-packages')));
        } else if (f.extract != null) {
          await extractMembers(file, f.extract!, staging);
        } else {
          await file.copy(path.join(staging.path, f.name));
        }
      }
      if (Platform.isMacOS) {
        // Downloads made by the app are not quarantined today, but a mirror
        // copy may be; a quarantined dylib is killed on load.
        await Process.run('xattr', ['-cr', staging.path]);
      }
      for (final f in fetched.keys.where((f) => f.executable)) {
        await prepareExecutable(File(path.join(staging.path, f.name)));
      }
      await File(path.join(staging.path, markerName)).writeAsString(jsonEncode({
        'id': manifest.id,
        'version': manifest.version,
        'platform': platformId,
      }));

      if (await old.exists()) await old.delete(recursive: true);
      if (await dest.exists()) await dest.rename(old.path);
      await staging.rename(dest.path);
      if (await old.exists()) await old.delete(recursive: true);
      await downloads.delete(recursive: true);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Make a downloaded program runnable: the executable bit (a download
  /// has none), and on macOS a signature. Apple Silicon refuses to run an
  /// unsigned arm64 binary at all, and upstream's Intel build is unsigned;
  /// one that verifies (DeepFilterNet's arm64 build is linker-signed) is left
  /// as it is. Quarantine was cleared with the rest of the install above.
  static Future<void> prepareExecutable(File file) async {
    if (Platform.isWindows) return;
    final chmod = await Process.run('chmod', ['755', file.path]);
    if (chmod.exitCode != 0) {
      throw StateError('Could not make ${path.basename(file.path)} executable: ${chmod.stderr}');
    }
    if (!Platform.isMacOS) return;
    final verify = await Process.run('codesign', ['--verify', file.path]);
    if (verify.exitCode == 0) return;
    final sign = await Process.run('codesign', ['--sign', '-', '--force', file.path]);
    if (sign.exitCode != 0) {
      throw StateError('Could not sign ${path.basename(file.path)}: ${sign.stderr}');
    }
  }

  /// Get [f] into [file], from the mirror if one is set and holds it, else
  /// the network; either way it must match its size and hash.
  Future<void> _fetch(AddonManifestFile f, File file, AddonManager downloader) async {
    if (await file.exists() && await _matches(file, f)) return;
    final mirrorDir = mirror;
    final source = mirrorDir == null
        ? null
        : File(path.join(mirrorDir, Uri.parse(f.url).pathSegments.last));
    if (source != null && await source.exists()) {
      await source.copy(file.path);
    } else {
      await downloader.downloadFile(f.url, file, expectedSize: f.size, expectedSha256: f.sha256);
      if (downloader.isCancelled) return;
    }
    if (!await _matches(file, f)) {
      final actual = await sha256OfFile(file);
      final length = await file.length();
      await file.delete();
      throw StateError('${f.name} does not match the pinned size and hash '
          '(got $length bytes, sha256 $actual; expected ${f.size} bytes, sha256 ${f.sha256})');
    }
  }

  static Future<bool> _matches(File file, AddonManifestFile f) async =>
      await file.length() == f.size && await sha256OfFile(file) == f.sha256;

  static Future<String> sha256OfFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  /// A wheel's contents into [siteDir], as pip lays them out: `*.data/purelib`
  /// and `*.data/platlib` go to the top, other `.data` directories (scripts,
  /// headers) are left out.
  static Future<void> extractWheel(File wheel, Directory siteDir) async {
    final input = InputFileStream(wheel.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        var rel = entry.name.replaceAll('\\', '/');
        final data = RegExp(r'^[^/]+\.data/([^/]+)/(.*)$').firstMatch(rel);
        if (data != null) {
          if (data.group(1) != 'purelib' && data.group(1) != 'platlib') continue;
          rel = data.group(2)!;
        }
        final out = File(_safeJoin(siteDir.path, rel));
        await out.parent.create(recursive: true);
        final stream = OutputFileStream(out.path);
        entry.writeContent(stream);
        await stream.close();
      }
    } finally {
      await input.close();
    }
  }

  /// The listed [members] of an archive into [into], each checked against its
  /// own hash; nothing else in the archive is written, and nothing at all if
  /// one is missing or wrong.
  static Future<void> extractMembers(
      File zip, List<AddonArchiveMember> members, Directory into) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final found = <AddonArchiveMember, List<int>>{};
      for (final m in members) {
        final entry = archive.files.where((f) => f.isFile && f.name.replaceAll('\\', '/') == m.path);
        if (entry.isEmpty) throw StateError('${m.path} is missing from ${path.basename(zip.path)}');
        final bytes = entry.first.content as List<int>;
        final actual = sha256.convert(bytes).toString();
        if (actual != m.sha256) {
          throw StateError('${m.path} does not match its expected hash ($actual)');
        }
        found[m] = bytes;
      }
      await into.create(recursive: true);
      for (final MapEntry(key: m, value: bytes) in found.entries) {
        await File(path.join(into.path, m.name)).writeAsBytes(bytes);
      }
    } finally {
      await input.close();
    }
  }

  /// [rel] under [root], refusing a path that would land outside it.
  static String _safeJoin(String root, String rel) {
    final joined = path.normalize(path.join(root, rel));
    if (path.isAbsolute(rel) || !path.isWithin(root, joined)) {
      throw StateError('Archive entry escapes its directory: $rel');
    }
    return joined;
  }

  @override
  Future<void> remove(Directory addonsDir) async {
    final dir = target(addonsDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
