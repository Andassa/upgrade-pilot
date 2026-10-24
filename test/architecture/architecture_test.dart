import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Layers of `lib/src` and the internal layers each may import.
/// Dependencies point towards `domain`; only `infra` touches the machine.
const allowedInternal = <String, Set<String>>{
  'domain': {},
  'ports': {'domain'},
  'analysis': {'domain', 'ports'},
  'kb': {'domain', 'ports'},
  'diagnose': {'domain'},
  'patch': {'domain', 'analysis'},
  'sandbox': {'domain', 'ports'},
  'sdk': {'domain', 'ports'},
  'verify': {'domain', 'ports', 'diagnose'},
  'resolver': {'domain', 'ports', 'kb', 'diagnose', 'verify'},
  'report': {'domain'},
  'ui': {'domain', 'ports'},
  'application': {
    'domain', 'ports', 'analysis', 'kb', 'diagnose', 'patch', 'sandbox', //
    'sdk', 'verify', 'resolver', 'report',
  },
  'infra': {'domain', 'ports'},
  'cli': {
    'domain', 'ports', 'analysis', 'kb', 'diagnose', 'patch', 'sandbox', //
    'sdk', 'verify', 'resolver', 'report', 'ui', 'application', 'infra',
  },
};

/// External packages allowed in the pure core.
const pureExternal = {
  'meta',
  'pub_semver',
  'crypto',
  'path',
  'yaml',
  'yaml_edit',
};

final _import =
    RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

Map<String, List<String>> _importsByFile() {
  final result = <String, List<String>>{};
  for (final entity in Directory('lib/src').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    result[entity.path] = _import
        .allMatches(entity.readAsStringSync())
        .map((m) => m.group(1)!)
        .toList();
  }
  return result;
}

String _layer(String path) => p.split(p.relative(path, from: 'lib/src')).first;

void main() {
  final files = _importsByFile();

  test('every file belongs to a known layer', () {
    for (final path in files.keys) {
      final layer = _layer(path);
      if (layer.endsWith('.dart')) continue;
      expect(allowedInternal, contains(layer), reason: path);
    }
  });

  test('internal imports follow the dependency rules', () {
    final violations = <String>[];
    for (final MapEntry(key: path, value: imports) in files.entries) {
      final layer = _layer(path);
      if (layer.endsWith('.dart')) continue;
      for (final import in imports) {
        const prefix = 'package:upgrade_pilot/src/';
        if (!import.startsWith(prefix)) continue;
        final target = import.substring(prefix.length).split('/').first;
        if (target.endsWith('.dart') || target == layer) continue;
        if (!allowedInternal[layer]!.contains(target)) {
          violations.add('$path imports $import');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('only infra uses dart:io, dart:ffi or the network', () {
    final violations = <String>[];
    for (final MapEntry(key: path, value: imports) in files.entries) {
      if (_layer(path) == 'infra') continue;
      for (final import in imports) {
        if (import == 'dart:io' ||
            import == 'dart:ffi' ||
            import.startsWith('package:http/')) {
          violations.add('$path imports $import');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('the pure core only uses pure packages', () {
    const core = {
      'domain',
      'analysis',
      'kb',
      'diagnose',
      'patch',
      'report',
      'resolver',
    };
    final violations = <String>[];
    for (final MapEntry(key: path, value: imports) in files.entries) {
      if (!core.contains(_layer(path))) continue;
      for (final import in imports) {
        if (!import.startsWith('package:') ||
            import.startsWith('package:upgrade_pilot/')) {
          continue;
        }
        final package = import.substring('package:'.length).split('/').first;
        if (!pureExternal.contains(package)) {
          violations.add('$path imports $import');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('no shell execution anywhere', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = entity.readAsStringSync();
      expect(content, isNot(contains('runInShell: true')), reason: entity.path);
      expect(content, isNot(contains("'sh', ['-c'")), reason: entity.path);
      expect(content, isNot(contains("'bash', ['-c'")), reason: entity.path);
    }
  });

  test('no TODO, FIXME or placeholder left in lib/', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      expect(
        entity.readAsStringSync(),
        isNot(matches(RegExp(r'\b(TODO|FIXME|XXX|HACK)\b'))),
        reason: entity.path,
      );
    }
  });

  test('pubspec version matches packageVersion', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    final source = File('lib/src/version.dart').readAsStringSync();
    expect(source, contains("packageVersion = '$version'"));
  });
}
