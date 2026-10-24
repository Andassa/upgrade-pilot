import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/patch/edit.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Sets the constraint of dependency [name] in `pubspec.yaml`, keeping
/// comments and formatting. Git, path and sdk dependencies are left alone
/// (reported as not found).
Edit setDependencyConstraint(String content, String name, String constraint) {
  final doc = loadYaml(content);
  if (doc is! YamlMap) return unchanged(content, found: false);
  for (final section in const ['dependencies', 'dev_dependencies']) {
    final deps = doc[section];
    if (deps is! YamlMap || !deps.containsKey(name)) continue;
    final current = deps[name];
    final editor = YamlEditor(content);
    if (current == null || current is String) {
      if (current == constraint) return unchanged(content, found: true);
      editor.update([section, name], constraint);
    } else if (current is YamlMap &&
        current.containsKey('version') &&
        !current.containsKey('git') &&
        !current.containsKey('path') &&
        !current.containsKey('sdk')) {
      editor.update([section, name, 'version'], constraint);
    } else {
      return unchanged(content, found: false);
    }
    return edited(content, editor.toString());
  }
  return unchanged(content, found: false);
}

/// Widens `environment.sdk` so that it allows [dart], keeping its lower
/// bound when possible.
Edit widenSdkConstraint(String content, Version dart) {
  final doc = loadYaml(content);
  final env = doc is YamlMap ? doc['environment'] : null;
  final raw = env is YamlMap ? env['sdk'] : null;
  if (raw is! String) return unchanged(content, found: false);
  final VersionConstraint current;
  try {
    current = VersionConstraint.parse(raw);
  } on FormatException {
    return unchanged(content, found: false);
  }
  if (current.allows(dart)) return unchanged(content, found: true);
  final lower = current is VersionRange ? current.min : null;
  final nextMajor = Version(dart.major + 1, 0, 0);
  final widened = lower != null && lower <= dart
      ? '>=$lower <$nextMajor'
      : '^${Version(dart.major, dart.minor, 0)}';
  final editor = YamlEditor(content)..update(['environment', 'sdk'], widened);
  return edited(content, editor.toString());
}
