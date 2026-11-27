// Every library the deps bundle carries or compiles against, and every build
// tool that shapes a binary, is pinned (task #114).
//
// source_pin_test.dart (task #110) pins what the scripts clone and download.
// Three more inputs moved under a rebuild of the same deps version:
// - macOS took zimg (VapourSynth's resize), boost (NNEDI3CL) and fftw's
//   headers from Homebrew bottles, whatever version Homebrew had that day;
//   the x64 source builds were pinned by version only, with no hash.
// - `pip install cython meson` took whatever PyPI had (both ship in the
//   bundle's site-packages, and meson runs every build).
// - Linux copied fftw, boost, libdvdread and the OpenCL loader from whatever
//   apt installed; boost came from noble-updates, which moves.
// So: Homebrew installs build tools only and nothing reads a library from it;
// the macOS support libraries come from tarballs checked against a SHA-256;
// pip installs take hash-pinned files in Scripts/pins/; Linux installs the apt
// packages from Scripts/pins/apt-linux.txt (a snapshot of the archive) and
// checks them before it copies one.
//
// This reads the scripts only; it needs no deps bundle.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _repoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'CLAUDE.md')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not find the repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}

String _read(String relative) =>
    File(p.join(_repoRoot(), relative)).readAsStringSync().replaceAll('\r\n', '\n');

/// Lines that are not shell/YAML comments, with their 1-based numbers.
Iterable<(int, String)> _code(String text) sync* {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('#')) continue;
    yield (i + 1, lines[i]);
  }
}

/// Logical lines (backslash continuations joined), comments dropped.
List<(int, String)> _logical(String text) {
  final out = <(int, String)>[];
  var start = 0;
  var buf = StringBuffer();
  for (final (n, l) in _code(text)) {
    if (buf.isEmpty) start = n;
    if (l.trimRight().endsWith(r'\')) {
      final t = l.trimRight();
      buf.write('${t.substring(0, t.length - 1)} ');
    } else {
      buf.write(l);
      out.add((start, buf.toString()));
      buf = StringBuffer();
    }
  }
  return out;
}

/// The literal a script assigns to [name] (`NAME="value"` at a line start).
String? _literal(String script, String name) =>
    RegExp('^$name="([^"\$]*)"', multiLine: true).firstMatch(script)?.group(1);

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// A pip requirements file: requirement name -> (version, hashes).
Map<String, (String, List<String>)> _requirements(String text) {
  final out = <String, (String, List<String>)>{};
  for (final (n, line) in _logical(text)) {
    if (line.trim().isEmpty) continue;
    final m = RegExp(r'^([A-Za-z0-9_.-]+)==([^\s]+)((?:\s+--hash=sha256:\S+)+)\s*$')
        .firstMatch(line.trim());
    if (m == null) {
      fail('line $n is not "<name>==<version> --hash=sha256:<hex> ...": $line');
    }
    final hashes = [
      for (final h in RegExp(r'--hash=sha256:(\S+)').allMatches(m.group(3)!)) h.group(1)!,
    ];
    for (final h in hashes) {
      expect(h, matches(_sha256), reason: 'line $n: $h is not a SHA-256');
    }
    out[m.group(1)!.toLowerCase()] = (m.group(2)!, hashes);
  }
  return out;
}

/// Scripts/pins/apt-linux.txt: the snapshot and its <package version role> rows.
(String?, List<(String, String, String)>) _aptPins() {
  String? snapshot;
  final rows = <(String, String, String)>[];
  for (final (n, line) in _code(_read('Scripts/pins/apt-linux.txt'))) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (line.trim().isEmpty) continue;
    if (f.length == 2 && f[0] == 'snapshot') {
      snapshot = f[1];
    } else if (f.length == 3) {
      rows.add((f[0], f[1], f[2]));
    } else {
      fail('apt-linux.txt:$n is neither "snapshot <id>" nor "<package> <version> <role>"');
    }
  }
  return (snapshot, rows);
}

const _scripts = ['Scripts/download-deps-macos.sh', 'Scripts/download-deps-linux.sh'];
const _workflows = [
  '.github/workflows/build-deps-macos.yml',
  '.github/workflows/build-deps-linux.yml',
  '.github/workflows/build-deps-windows.yml',
];

void main() {
  final mac = _read('Scripts/download-deps-macos.sh');
  final linux = _read('Scripts/download-deps-linux.sh');

  group('macOS takes no library from Homebrew', () {
    const libraries = {'zimg', 'fftw', 'boost', 'ffmpeg'};

    test('BREW_DEPS lists build tools only', () {
      final m = RegExp(r'^BREW_DEPS=\(\n([\s\S]*?)\n\)', multiLine: true).firstMatch(mac);
      expect(m, isNotNull, reason: 'download-deps-macos.sh must declare BREW_DEPS=( ... )');
      final deps = [
        for (final (_, l) in _code(m!.group(1)!)) ...l.trim().split(RegExp(r'\s+')),
      ].where((w) => w.isNotEmpty).toSet();
      expect(deps.intersection(libraries), isEmpty,
          reason: 'zimg, fftw and boost are built from pinned releases (srclib), and '
              "Homebrew's ffmpeg pulls zimg back in (task #114)");
    });

    test('nothing reads a library, header or .pc from the Homebrew prefix', () {
      for (final (n, line) in _code(mac)) {
        for (final bad in [
          RegExp(r'\$\{?BREW_PREFIX\}?/lib/'),
          RegExp(r'\$\{?BREW_PREFIX\}?/opt/(zimg|fftw|boost)'),
          RegExp(r'\$\{?BREW_PREFIX\}?/include'),
          RegExp(r'brew --prefix \w'),
        ]) {
          expect(bad.hasMatch(line), isFalse,
              reason: 'download-deps-macos.sh:$n reads Homebrew\'s copy: $line (task #114)');
        }
      }
    });

    test('every support library tarball is checked against a pinned SHA-256', () {
      for (final name in [
        'ZIMG_VERSION_ARM64', 'ZIMG_VERSION_X64', 'BOOST_VERSION_ARM64', 'BOOST_VERSION_X64',
        'FFTW_VERSION',
      ]) {
        expect(_literal(mac, name), matches(RegExp(r'^\d+\.\d+\.\d+$')),
            reason: '$name must be a literal release version');
      }
      for (final name in [
        'ZIMG_SHA256_ARM64', 'ZIMG_SHA256_X64', 'BOOST_SHA256_ARM64', 'BOOST_SHA256_X64',
        'FFTW_SHA256',
      ]) {
        expect(_literal(mac, name), matches(_sha256), reason: '$name must be a literal SHA-256');
      }
      final start = mac.indexOf('SRCLIB_STAMP=');
      final end = mac.indexOf('# Download and embed Python framework');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final block = mac.substring(start, end);
      final fetches = [
        for (final (_, l) in _logical(block))
          if (l.trimLeft().startsWith('fetch_verified ')) l.trim(),
      ];
      expect(fetches, hasLength(3), reason: 'fftw, zimg and boost each go through fetch_verified');
      for (final f in fetches) {
        expect(f, matches(RegExp(r'"\$(FFTW|ZIMG|BOOST)_SHA256"$')),
            reason: 'each fetch must pass its *_SHA256: $f');
      }
      for (final (n, l) in _logical(block)) {
        expect(RegExp(r'(^|[;&|]\s*)curl\s').hasMatch(l.trimLeft()), isFalse,
            reason: 'srclib line $n downloads without a hash check: $l');
      }
      // The helper really compares the hash and exits.
      final helper = RegExp(r'^fetch_verified\(\) \{\n([\s\S]*?)\n\}', multiLine: true)
          .firstMatch(mac)
          ?.group(1);
      expect(helper, isNotNull);
      expect(helper, contains('shasum -a 256'));
      expect(helper, contains('exit 1'));
    });

    test("VapourSynth's meson setup links the pinned zimg, and checks it", () {
      final setup = RegExp(r'^\s*PKG_CONFIG_PATH="\$SRCLIB/lib/pkgconfig" "\$PYTHON_BIN" -m '
          r'mesonbuild\.mesonmain setup build', multiLine: true);
      expect(setup.hasMatch(mac), isTrue,
          reason: 'the setup must be given srclib\'s zimg.pc, and nothing else (task #114)');
      expect(mac, contains(r'Run-time dependency zimg found: YES $ZIMG_VERSION'),
          reason: 'the build must fail unless meson found the pinned zimg');
      expect(mac, contains('Executing subproject zimg'),
          reason: "the build must fail if meson fell back to R78's unpinned zimg.wrap");
      expect(mac, contains(r'cp "$SRCLIB/lib/libzimg.2.dylib" "$DEPS_DIR/vapoursynth/libzimg.dylib"'));
      expect(mac, contains(r'[ "$VS_ZIMG_REF" != "$SRCLIB/lib/libzimg.2.dylib" ]'),
          reason: 'libvapoursynth must be checked to link the zimg that is bundled');
    });

    test('the meson plugins and the FFTW plugins compile against srclib', () {
      expect(RegExp(r'^\s*FFTW_INC="\$SRCLIB/include"', multiLine: true).allMatches(mac).length,
          greaterThanOrEqualTo(3));
      for (final plugin in ['nnedi3cl', 'knlmeanscl']) {
        final calls = RegExp('build_plugin "$plugin" [^\\n]*\\n(?:[^\\n]*\\\\\\n)*[^\\n]*')
            .allMatches(mac)
            .map((m) => m.group(0)!)
            .toList();
        expect(calls, isNotEmpty, reason: 'arm64 builds $plugin through build_plugin');
        for (final c in calls) {
          expect(c, contains(r'BOOST_ROOT=\"\$SRCLIB\"'),
              reason: 'arm64 $plugin must compile against the pinned boost');
        }
      }
    });
  });

  group('pip installs are hash-pinned', () {
    test('Scripts/pins/pip-*.txt pin one version, by hash', () {
      final cython = _requirements(_read('Scripts/pins/pip-cython.txt'));
      final meson = _requirements(_read('Scripts/pins/pip-meson.txt'));
      expect(cython.keys, ['cython']);
      expect(meson.keys, ['meson']);
      // macOS arm64 and x86_64, Linux x86_64 and aarch64.
      expect(cython['cython']!.$2, hasLength(4),
          reason: 'one hash per wheel the four bundles install');
      expect(meson['meson']!.$2, hasLength(1), reason: "meson's one universal wheel");
    });

    test('no pip install takes anything but a pins file, with --require-hashes', () {
      for (final file in [..._scripts, ..._workflows]) {
        final text = _read(file);
        for (final (n, line) in _logical(text)) {
          final m = RegExp(r'(?:^|[\s"])(?:pip3?|-m pip) install\b(.*)$').firstMatch(line);
          if (m == null) continue;
          if (RegExp(r'^\s*echo ').hasMatch(line)) continue;
          final args = m.group(1)!.split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList();
          expect(args, containsAll(['--require-hashes', '--only-binary']),
              reason: '$file:$n installs without hashes: $line (task #114)');
          for (var i = 0; i < args.length; i++) {
            final a = args[i];
            if (a.startsWith('-')) {
              if (a == '-r') {
                expect(args[i + 1], matches(RegExp(r'pins/pip-[a-z]+\.txt"?$')),
                    reason: '$file:$n: -r must name a Scripts/pins/ file');
                i++;
              } else if (a == '--only-binary') {
                i++;
              }
              continue;
            }
            fail('$file:$n names a package directly ("$a"); use a Scripts/pins/ file');
          }
        }
      }
    });

    test('both scripts install Cython and meson from the pins and check them', () {
      for (final (file, text) in [(_scripts[0], mac), (_scripts[1], linux)]) {
        expect(text, contains(r'-r "$SCRIPT_DIR/pins/pip-cython.txt" -r "$SCRIPT_DIR/pins/pip-meson.txt"'),
            reason: file);
        expect(text, contains(r'print(Cython.__version__, c.version)'),
            reason: '$file must check the versions the embedded Python ended up with');
      }
    });
  });

  group('Linux installs the apt packages it bundles at pinned versions', () {
    final (snapshot, rows) = _aptPins();

    test('apt-linux.txt names a snapshot and well-formed pins', () {
      expect(snapshot, matches(RegExp(r'^\d{8}T\d{6}Z$')));
      expect(rows, isNotEmpty);
      final names = <String>{};
      for (final (pkg, version, role) in rows) {
        expect({'bundled', 'install', 'dep'}, contains(role), reason: '$pkg: role $role');
        expect(version, matches(RegExp(r'^[0-9][A-Za-z0-9.+~:-]*$')), reason: pkg);
        expect(names.add(pkg), isTrue, reason: '$pkg is listed twice');
      }
    });

    test('every library the script copies from the system is a bundled pin', () {
      // Which package each copied library comes from on noble.
      const owner = {
        'libfftw3f.so': 'libfftw3-single3',
        'libfftw3f_threads.so': 'libfftw3-single3',
        'libboost_filesystem.so': 'libboost-filesystem1.83.0',
        'libboost_atomic.so': 'libboost-atomic1.83.0',
        'libOpenCL.so': 'ocl-icd-libopencl1',
        'libdvdread.so': 'libdvdread8t64',
      };
      final bundled = {for (final (pkg, _, role) in rows) if (role == 'bundled') pkg};
      final copies = [
        for (final (n, l) in _code(linux))
          if (RegExp(r'cp -L "\$libdir/([^"]+)"').firstMatch(l) case final m?) (n, m.group(1)!),
      ];
      expect(copies, isNotEmpty);
      for (final (n, lib) in copies) {
        expect(owner, contains(lib),
            reason: 'download-deps-linux.sh:$n copies $lib from the system: add its package '
                'to Scripts/pins/apt-linux.txt as bundled, and to this map');
        expect(bundled, contains(owner[lib]),
            reason: '${owner[lib]} (for $lib) must be pinned as bundled');
      }
    });

    test('the script checks the pins before copying anything', () {
      final check = linux.indexOf(r'"$SCRIPT_DIR/pins/apt-linux.txt"');
      final firstCopy = linux.indexOf(r'cp -L "$libdir/');
      expect(check, greaterThan(0), reason: 'download-deps-linux.sh must read apt-linux.txt');
      expect(check, lessThan(firstCopy));
      expect(linux, contains(r"dpkg-query -W -f='${db:Status-Abbrev} ${Version}'"));
      expect(linux, contains(r'"meson on PATH is'),
          reason: 'the plugin builds\' meson must be checked against the pin');
    });

    test('build-deps-linux.yml installs the pins and nothing pinned by name', () {
      final yml = _read('.github/workflows/build-deps-linux.yml');
      expect(RegExp(r'^\s*\./Scripts/install-apt-pins-linux\.sh\s*$', multiLine: true)
          .allMatches(yml)
          .length, 2, reason: 'both jobs (x64 and arm64)');
      final pinned = {for (final (pkg, _, _) in rows) pkg};
      // The metapackage names the workflow used to install.
      pinned.addAll(['libfftw3-dev', 'libboost-filesystem-dev', 'cython3', 'opencl-headers']);
      for (final (n, line) in _logical(yml)) {
        if (!line.contains('apt-get install') && !line.contains('apt install')) continue;
        for (final w in line.split(RegExp(r'\s+'))) {
          expect(pinned.contains(w), isFalse,
              reason: 'build-deps-linux.yml:$n installs $w unpinned; it is in apt-linux.txt');
        }
      }
    });

    test('the installer uses the snapshot and pins every listed package', () {
      final installer = _read('Scripts/install-apt-pins-linux.sh');
      expect(installer, contains(r'https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT/'));
      expect(installer, contains('Pin-Priority: 1001'));
      expect(installer, contains(r'pins/apt-linux.txt'));
    });
  });
}
