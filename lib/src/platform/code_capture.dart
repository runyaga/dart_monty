/// Shared utilities for capturing the last expression in user code.
///
/// Used by both `MontySession` and `AgentSession` to wrap the trailing
/// expression as `__r = (expr)` so it becomes the execution's return value.
library;

/// Matches simple assignment targets: `identifier = ...`
///
/// Only captures a single identifier before `=`.
/// Excludes `==` (comparison) and augmented assignments (`+=`, etc.).
final assignmentPattern = RegExp(r'^([a-zA-Z]\w*)\s*=[^=]', multiLine: true);

/// Python keyword prefixes that indicate a line is a statement (not an
/// expression). Used to detect the user code's last expression so it can
/// be captured before the persist postamble runs.
const statementPrefixes = [
  'if ',
  'for ',
  'while ',
  'with ',
  'try:',
  'def ',
  'class ',
  'import ',
  'from ',
  'raise ',
  'return ',
  'pass',
  'break',
  'continue',
  'assert ',
];

/// Checks whether [line] looks like a Python expression (not a statement).
///
/// Returns `false` for lines starting with known statement keywords,
/// assignments (`name = ...`), or empty/comment lines.
bool isExpression(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('#')) return false;

  for (final prefix in statementPrefixes) {
    if (trimmed.startsWith(prefix) || trimmed == prefix.trim()) return false;
  }

  if (assignmentPattern.hasMatch(trimmed)) return false;

  return true;
}

/// Processes [userCode] to capture the last expression's value.
///
/// If the trailing non-empty lines form an expression (single-line or
/// multi-line via brackets), replaces the expression with
/// `__r = (expression)` and returns `(modifiedCode, true)`.
///
/// Multi-line expressions are detected by scanning backwards from the
/// last non-empty line, tracking `()`, `[]`, and `{}` depth. A dict
/// literal, list literal, or function call spanning multiple lines is
/// captured as a single expression.
///
/// If the last line is a statement (or there is no code), returns
/// `(userCode, false)`.
(String, bool) captureLastExpression(String userCode) {
  final lines = userCode.split('\n');

  // Find last non-empty, non-comment line index.
  var lastIdx = -1;
  for (var i = lines.length - 1; i >= 0; i--) {
    final trimmed = lines[i].trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      lastIdx = i;
      break;
    }
  }

  if (lastIdx < 0) return (userCode, false);

  // Find where the expression actually starts. For multi-line
  // expressions (dict/list/tuple literals, multi-line calls), scan
  // backwards tracking bracket depth to find the opening line.
  final startIdx = _findExpressionStart(lines, lastIdx);

  // Check whether the first line of the expression is a statement.
  if (!isExpression(lines[startIdx])) return (userCode, false);

  // Join the (possibly multi-line) expression and wrap it.
  final exprLines = lines.sublist(startIdx, lastIdx + 1);
  final expr = exprLines.join('\n');

  final result = [
    ...lines.sublist(0, startIdx),
    '__r = ($expr)',
    ...lines.sublist(lastIdx + 1),
  ];

  return (result.join('\n'), true);
}

/// Extracts top-level assignment target names from [code].
///
/// Only considers lines with no leading whitespace (top-level).
/// Handles semicolons for multi-statement lines.
/// Excludes names starting with `_` (internal/dunder).
Set<String> extractAssignmentTargets(String code) {
  final names = <String>{};
  for (final line in code.split('\n')) {
    if (line.isNotEmpty && line[0] != ' ' && line[0] != '\t') {
      for (final segment in line.split(';')) {
        final match = assignmentPattern.firstMatch(segment.trimLeft());
        if (match != null) {
          final name = match.group(1)!;
          if (!name.startsWith('_')) {
            names.add(name);
          }
        }
      }
    }
  }

  return names;
}

/// Scans backwards from [lastIdx] tracking bracket depth to find where
/// a multi-line expression begins (e.g. `{\n  "a": 1,\n}`).
///
/// Returns [lastIdx] when the last line is a complete single-line
/// expression. Returns an earlier index when unclosed brackets indicate
/// the expression spans multiple lines.
int _findExpressionStart(List<String> lines, int lastIdx) {
  var depth = 0;

  for (var i = lastIdx; i >= 0; i--) {
    final line = lines[i];

    // Scan characters, skipping content inside string literals.
    var inSingle = false;
    var inDouble = false;
    var escaped = false;

    for (var c = 0; c < line.length; c++) {
      final ch = line[c];

      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }

      if (!inDouble && ch == "'") {
        inSingle = !inSingle;
      } else if (!inSingle && ch == '"') {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (ch == ')' || ch == ']' || ch == '}') {
          depth++;
        } else if (ch == '(' || ch == '[' || ch == '{') {
          depth--;
        }
      }
    }

    // depth <= 0 means this line has at least as many openers as closers
    // seen so far — the expression starts here.
    if (depth <= 0) return i;
  }

  return 0;
}
