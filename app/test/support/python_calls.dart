// Reading Python call sites and signatures as text, for tests that check the
// script templates' keyword arguments against what they call (task #42).

/// The text between the bracket at [open] and its matching close.
String balancedArgs(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return s.substring(open + 1, i);
    }
  }
  throw StateError('unbalanced bracket at $open');
}

/// [args] split on commas at bracket depth 0, trimmed, empties dropped.
List<String> topLevelArgs(String args) {
  final parts = <String>[];
  var depth = 0, start = 0;
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      parts.add(args.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(args.substring(start));
  return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

/// One call of a function matched by [callPattern] (whose last character is
/// the opening paren and whose group 1 names the function): its name, its
/// 1-based line, and the keyword names it passes. Template tag lines
/// (`{{#X}}` / `{{/X}}`) between arguments are dropped first; `**kwargs`
/// spreads are not keywords.
class PythonCall {
  PythonCall(this.name, this.line, this.keywords);
  final String name;
  final int line;
  final List<String> keywords;
}

final _tagLine = RegExp(r'^\s*\{\{[#/]\w+\}\}\s*$');
final _keyword = RegExp(r'^(\w+)\s*=(?!=)');

List<PythonCall> pythonCalls(String source, RegExp callPattern) {
  final calls = <PythonCall>[];
  for (final m in callPattern.allMatches(source)) {
    final body = balancedArgs(source, m.end - 1)
        .split('\n')
        .where((l) => !_tagLine.hasMatch(l))
        .join('\n');
    final keywords = [
      for (final arg in topLevelArgs(body))
        if (_keyword.firstMatch(arg) case final k?) k.group(1)!,
    ];
    final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
    calls.add(PythonCall(m.group(1)!, line, keywords));
  }
  return calls;
}
