import 'package:upgrade_pilot/src/domain/change.dart';

/// Line-level edit operation.
enum DiffOp { equal, insert, delete }

typedef DiffLine = ({DiffOp op, String text});

/// Myers-style shortest edit script between two line lists (LCS based;
/// project files are small enough for the quadratic table).
List<DiffLine> diffLines(List<String> a, List<String> b) {
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final midA = a.sublist(start, endA);
  final midB = b.sublist(start, endB);
  final n = midA.length;
  final m = midB.length;
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = midA[i] == midB[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final result = <DiffLine>[
    for (final line in a.take(start)) (op: DiffOp.equal, text: line),
  ];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (midA[i] == midB[j]) {
      result.add((op: DiffOp.equal, text: midA[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      result.add((op: DiffOp.delete, text: midA[i++]));
    } else {
      result.add((op: DiffOp.insert, text: midB[j++]));
    }
  }
  while (i < n) {
    result.add((op: DiffOp.delete, text: midA[i++]));
  }
  while (j < m) {
    result.add((op: DiffOp.insert, text: midB[j++]));
  }
  result.addAll([
    for (final line in a.skip(endA)) (op: DiffOp.equal, text: line),
  ]);
  return result;
}

List<String> _lines(String? text) {
  if (text == null || text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Unified diff (`git diff` style) of one file. Empty when identical.
String unifiedDiff(
  String path,
  String? before,
  String after, {
  int context = 3,
}) {
  final a = _lines(before);
  final b = _lines(after);
  final ops = diffLines(a, b);
  if (ops.every((o) => o.op == DiffOp.equal)) return '';
  final buffer = StringBuffer()
    ..writeln(before == null ? '--- /dev/null' : '--- a/$path')
    ..writeln('+++ b/$path');
  var index = 0;
  while (index < ops.length) {
    if (ops[index].op == DiffOp.equal) {
      index++;
      continue;
    }
    var hunkStart = (index - context).clamp(0, ops.length);
    var hunkEnd = index;
    var lastChange = index;
    while (hunkEnd < ops.length) {
      if (ops[hunkEnd].op != DiffOp.equal) lastChange = hunkEnd;
      if (hunkEnd - lastChange > context * 2) break;
      hunkEnd++;
    }
    hunkEnd = (lastChange + context + 1).clamp(0, ops.length);
    var lineA = 1;
    var lineB = 1;
    for (var k = 0; k < hunkStart; k++) {
      if (ops[k].op != DiffOp.insert) lineA++;
      if (ops[k].op != DiffOp.delete) lineB++;
    }
    final hunk = ops.sublist(hunkStart, hunkEnd);
    final countA = hunk.where((o) => o.op != DiffOp.insert).length;
    final countB = hunk.where((o) => o.op != DiffOp.delete).length;
    buffer.writeln(
      '@@ -${countA == 0 ? lineA - 1 : lineA},$countA '
      '+${countB == 0 ? lineB - 1 : lineB},$countB @@',
    );
    for (final line in hunk) {
      final sign = switch (line.op) {
        DiffOp.equal => ' ',
        DiffOp.insert => '+',
        DiffOp.delete => '-',
      };
      buffer.writeln('$sign${line.text}');
    }
    hunkStart = hunkEnd;
    index = hunkEnd;
  }
  return buffer.toString();
}

/// Zero-context hunks turning [before] into [after]. See [applyHunks].
List<Hunk> computeHunks(String? before, String after) {
  final ops = diffLines(splitLines(before), splitLines(after));
  final hunks = <Hunk>[];
  var line = 0;
  var index = 0;
  while (index < ops.length) {
    if (ops[index].op == DiffOp.equal) {
      line++;
      index++;
      continue;
    }
    final start = line;
    var deleted = 0;
    final inserted = <String>[];
    while (index < ops.length && ops[index].op != DiffOp.equal) {
      if (ops[index].op == DiffOp.delete) {
        deleted++;
        line++;
      } else {
        inserted.add(ops[index].text);
      }
      index++;
    }
    hunks.add(Hunk(start: start, deleteCount: deleted, insert: inserted));
  }
  return hunks;
}

/// Number of added and removed lines.
({int added, int removed}) diffStat(String? before, String after) {
  var added = 0;
  var removed = 0;
  for (final op in diffLines(_lines(before), _lines(after))) {
    if (op.op == DiffOp.insert) added++;
    if (op.op == DiffOp.delete) removed++;
  }
  return (added: added, removed: removed);
}
