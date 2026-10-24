import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Compares [actual] with `test/golden/goldens/<name>.txt`. The escape
/// character is stored as `␛` so that goldens stay readable in diffs.
/// Run with UPDATE_GOLDENS=1 (`make golden`) to rewrite them.
void expectGolden(String name, String actual) {
  final file = File(p.join('test', 'golden', 'goldens', '$name.txt'));
  final readable = actual.replaceAll('\x1B', '␛');
  if (Platform.environment['UPDATE_GOLDENS'] == '1' || !file.existsSync()) {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(readable);
    if (Platform.environment['UPDATE_GOLDENS'] != '1') {
      fail('Golden $name was missing and has been created; run again.');
    }
    return;
  }
  expect(
    readable,
    file.readAsStringSync(),
    reason: 'golden $name (make golden)',
  );
}
