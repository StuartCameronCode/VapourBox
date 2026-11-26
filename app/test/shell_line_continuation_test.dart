// No shell `\` line continuation may run into a comment or a blank line
// (task #111).
//
// bash ends the command there. Two deps-script blocks did it, and neither
// failed:
//  - download-deps-linux.sh (since 0c805a7b): `PATH=… PKG_CONFIG_PATH=…
//    LD_LIBRARY_PATH=… env CC=… CXX=… \` continued onto a comment, so the
//    command was a bare `env` (which printed the environment) and
//    VapourSynth's `meson setup` ran next with none of those variables.
//  - download-deps-macos.sh (since 3094c648): `PATH=… \ PKG_CONFIG_PATH=… \`
//    continued onto a comment, so the two became plain assignments that held
//    for the rest of the script.
// Each looked like a prefix of the command below it, so the script said one
// thing and built another.
//
// This scans every shell script under Scripts/, .github/scripts/ and
// packaging/ (by extension or shebang) and every workflow file as text,
// skipping heredoc bodies (their text is data, not commands).
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

final _heredoc = RegExp(r'''<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1''');

/// The line numbers (1-based) of lines that end in an unescaped `\` and are
/// followed by a blank or comment line, outside heredoc bodies.
List<int> brokenContinuations(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final found = <int>[];
  String? heredocEnd;
  var heredocTabs = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (heredocEnd != null) {
      final body = heredocTabs ? line.replaceFirst(RegExp(r'^\t+'), '') : line;
      if (body.trimRight() == heredocEnd) heredocEnd = null;
      continue;
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) continue;
    final m = _heredoc.firstMatch(line);
    if (m != null) {
      heredocEnd = m.group(2);
      heredocTabs = line.substring(m.start).startsWith('<<-');
    }
    final trailing = RegExp(r'\\+$').firstMatch(line.trimRight())?.group(0) ?? '';
    if (trailing.length.isOdd && i + 1 < lines.length) {
      final next = lines[i + 1].trim();
      if (next.isEmpty || next.startsWith('#')) found.add(i + 1);
    }
  }
  return found;
}

bool _isShell(File f) {
  final name = p.basename(f.path);
  if (name.endsWith('.sh')) return true;
  if (name.contains('.')) return false;
  try {
    final first = f.readAsLinesSync().first;
    return first.startsWith('#!') && first.contains('sh');
  } catch (_) {
    return false;
  }
}

void main() {
  group('the rule', () {
    test('catches the Linux shape (task #111)', () {
      const text = 'PATH="\$X:\$PATH" \\\n'
          'env \${VS_CC:+CC="\$VS_CC"} \\\n'
          '# Run meson with the EMBEDDED python\n'
          '"\$PYTHON_BIN" -m mesonbuild.mesonmain setup build\n';
      expect(brokenContinuations(text), [2]);
    });

    test('catches the macOS shape (task #111)', () {
      const text = '    PATH="\$PYTHON_DIR/bin:\$PATH" \\\n'
          '    PKG_CONFIG_PATH="\$BUILD_DIR/pkgconfig" \\\n'
          '    # meson looks for a "cython3" program\n'
          '    for cy in cython cython3; do\n';
      expect(brokenContinuations(text), [2]);
    });

    test('catches a continuation onto a blank line, with CRLF too', () {
      expect(brokenContinuations('make \\\r\n\r\necho done\r\n'), [1]);
    });

    test('passes a continuation inside a comment', () {
      const text = '# Prerequisites:\n'
          '#   sudo apt install build-essential \\\n'
          '#     libtool pkg-config\n'
          '\n';
      expect(brokenContinuations(text), isEmpty);
    });

    test('passes a heredoc body ending in a backslash', () {
      const text = "cat > x << 'EOF'\n"
          'a line \\\n'
          '\n'
          'EOF\n'
          'cat > y <<-CYEOF\n'
          '\tanother \\\n'
          '\t# not a comment here\n'
          '\tCYEOF\n'
          'echo done\n';
      expect(brokenContinuations(text), isEmpty);
    });

    test(r'passes an escaped backslash (\\) at the end of a line', () {
      expect(brokenContinuations('echo a\\\\\n# comment\n'), isEmpty);
    });

    test('passes a continuation onto a command', () {
      expect(brokenContinuations('ninja \\\n    -C build\n'), isEmpty);
    });
  });

  test('no script or workflow continues a line into a comment or blank line', () {
    final root = _repoRoot();
    final files = <File>[
      for (final dir in ['Scripts', '.github/scripts', 'packaging'])
        if (Directory(p.join(root, dir)).existsSync())
          ...Directory(p.join(root, dir))
              .listSync(recursive: true)
              .whereType<File>()
              .where(_isShell),
      ...Directory(p.join(root, '.github', 'workflows'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml')),
    ];
    expect(files.length, greaterThan(10), reason: 'the scan found too few files');
    final problems = <String>[];
    for (final f in files) {
      final text = f.readAsStringSync();
      final lines = text.replaceAll('\r\n', '\n').split('\n');
      for (final n in brokenContinuations(text)) {
        problems.add('${p.relative(f.path, from: root)}:$n\n'
            '    ${lines[n - 1].trim()}\n    ${lines[n].trim()}');
      }
    }
    expect(problems, isEmpty,
        reason: 'a `\\` continuation that runs into a comment or blank line ends '
            'the command there (task #111):\n${problems.join('\n')}');
  });
}
