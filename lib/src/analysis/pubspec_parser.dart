import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:yaml/yaml.dart';

/// Thrown when `pubspec.yaml` or `pubspec.lock` cannot be read.
final class ManifestException implements Exception {
  ManifestException(this.file, this.message);

  final String file;
  final String message;

  @override
  String toString() => '$file: $message';
}

/// Parses `pubspec.yaml`.
PubspecInfo parsePubspec(String content) {
  final Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException catch (e) {
    throw ManifestException('pubspec.yaml', e.message);
  }
  if (doc is! YamlMap) {
    throw ManifestException('pubspec.yaml', 'expected a YAML map');
  }
  final name = doc['name'];
  if (name is! String || name.isEmpty) {
    throw ManifestException('pubspec.yaml', 'missing "name"');
  }
  final env = doc['environment'];
  String? envValue(String key) =>
      env is YamlMap && env[key] != null ? '${env[key]}' : null;

  return PubspecInfo(
    name: name,
    dartConstraint: envValue('sdk'),
    flutterConstraint: envValue('flutter'),
    dependencies: [
      ..._dependencies(doc['dependencies'], isDev: false),
      ..._dependencies(doc['dev_dependencies'], isDev: true),
    ],
    hasWorkspace: doc['workspace'] is YamlList,
    resolutionWorkspace: doc['resolution'] == 'workspace',
  );
}

Iterable<DependencySpec> _dependencies(Object? node, {required bool isDev}) {
  if (node is! YamlMap) return const [];
  return node.entries.map((entry) {
    final name = '${entry.key}';
    final value = entry.value;
    if (value == null || value is String) {
      final constraint = value as String?;
      return DependencySpec(
        name: name,
        kind: DependencyKind.hosted,
        constraint: constraint == 'any' ? null : constraint,
        isDev: isDev,
      );
    }
    if (value is YamlMap) {
      final kind = value.containsKey('sdk')
          ? DependencyKind.sdk
          : value.containsKey('git')
              ? DependencyKind.git
              : value.containsKey('path')
                  ? DependencyKind.path
                  : DependencyKind.hosted;
      final version = value['version'];
      final path = value['path'];
      return DependencySpec(
        name: name,
        kind: kind,
        constraint: version is String ? version : null,
        isDev: isDev,
        path: path is String ? path : null,
      );
    }
    return DependencySpec(
      name: name,
      kind: DependencyKind.hosted,
      constraint: '$value',
      isDev: isDev,
    );
  });
}

/// Parses `pubspec.lock`. Returns an empty map for empty content.
Map<String, LockedPackage> parsePubspecLock(String content) {
  if (content.trim().isEmpty) return const {};
  final Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException catch (e) {
    throw ManifestException('pubspec.lock', e.message);
  }
  final packages = doc is YamlMap ? doc['packages'] : null;
  if (packages is! YamlMap) return const {};
  return {
    for (final entry in packages.entries)
      if (entry.value is YamlMap)
        '${entry.key}': LockedPackage(
          name: '${entry.key}',
          version: '${(entry.value as YamlMap)['version']}',
          source: '${(entry.value as YamlMap)['source']}',
          dependency: '${(entry.value as YamlMap)['dependency']}',
        ),
  };
}
