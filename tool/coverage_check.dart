// Enforces per-layer line coverage from coverage/lcov.info.
//
// Usage: dart run tool/coverage_check.dart [coverage/lcov.info]
import 'dart:io';

const strict = 85.0;
const relaxed = 70.0;
const strictLayers = {
  'domain',
  'analysis',
  'kb',
  'diagnose',
  'patch',
  'report',
  'ui',
};

void main(List<String> args) {
  final file = File(args.isEmpty ? 'coverage/lcov.info' : args.first);
  if (!file.existsSync()) {
    stderr.writeln('${file.path} not found: run `make test` first.');
    exit(1);
  }
  final hit = <String, int>{};
  final found = <String, int>{};
  String? layer;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      final path = line.substring(3).replaceAll(r'\', '/');
      final match = RegExp('lib/src/([^/]+)/').firstMatch(path);
      layer = match?.group(1) ?? 'root';
    } else if (line.startsWith('DA:') && layer != null) {
      final parts = line.substring(3).split(',');
      found[layer] = (found[layer] ?? 0) + 1;
      if (int.parse(parts[1]) > 0) hit[layer] = (hit[layer] ?? 0) + 1;
    }
  }
  var failed = false;
  final layers = found.keys.toList()..sort();
  var totalHit = 0;
  var totalFound = 0;
  for (final name in layers) {
    final h = hit[name] ?? 0;
    final f = found[name]!;
    totalHit += h;
    totalFound += f;
    final percent = f == 0 ? 100.0 : h * 100 / f;
    final threshold = strictLayers.contains(name) ? strict : relaxed;
    final ok = percent >= threshold;
    failed = failed || !ok;
    stdout.writeln(
      '${ok ? 'ok  ' : 'FAIL'} ${name.padRight(12)} '
      '${percent.toStringAsFixed(1).padLeft(5)}%  (min $threshold%, $h/$f lines)',
    );
  }
  stdout.writeln(
    'total        '
    '${(totalHit * 100 / totalFound).toStringAsFixed(1).padLeft(5)}%',
  );
  if (failed) exit(1);
}
