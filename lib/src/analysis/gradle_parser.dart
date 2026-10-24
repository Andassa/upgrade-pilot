import 'package:pub_semver/pub_semver.dart';

import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

final _distributionUrl = RegExp(
  r'^\s*distributionUrl\s*=.*gradle-([0-9][0-9A-Za-z.\-]*?)-(all|bin)\.zip',
  multiLine: true,
);

/// A Gradle distribution referenced by `gradle-wrapper.properties`.
typedef GradleDistribution = ({Version version, String type});

/// Reads the Gradle version from `gradle-wrapper.properties`.
GradleDistribution? parseGradleWrapper(String content) {
  final match = _distributionUrl.firstMatch(content);
  if (match == null) return null;
  final version = parseLooseVersion(match.group(1));
  if (version == null) return null;
  return (version: version, type: match.group(2)!);
}

// `id("com.android.application") version "8.1.0"` (Kotlin DSL) and
// `id "com.android.application" version "8.1.0"` (Groovy DSL).
RegExp _pluginVersion(String id) => RegExp(
      r'''id\s*\(?\s*["']''' +
          RegExp.escape(id) +
          r'''["']\s*\)?\s*version\s*\(?\s*["']([^"']+)["']''',
    );

final _agpClasspath = RegExp(
  r'''com\.android\.tools\.build:gradle:([0-9][^"'\s)]*)''',
);
final _kotlinExt = RegExp(
  r'''kotlin_version\s*=\s*["']([^"']+)["']''',
);
final _kotlinClasspath = RegExp(
  r'''org\.jetbrains\.kotlin:kotlin-gradle-plugin:([0-9][^"'\s)$]*)''',
);

/// Where a toolchain version was found.
typedef DeclaredVersion = ({Version version, String file});

/// Finds the Android Gradle Plugin version across the usual locations.
///
/// [files] maps a relative path to its content.
DeclaredVersion? findAgpVersion(Map<String, String> files) => _findVersion(
      files,
      [
        _pluginVersion('com.android.application'),
        _agpClasspath,
      ],
      tomlKeys: const [
        'agp',
        'android-gradle-plugin',
        'androidGradlePlugin',
      ],
    );

/// Finds the Kotlin Gradle Plugin version across the usual locations.
DeclaredVersion? findKotlinVersion(Map<String, String> files) => _findVersion(
      files,
      [
        _pluginVersion('org.jetbrains.kotlin.android'),
        _kotlinExt,
        _kotlinClasspath,
      ],
      tomlKeys: const [
        'kotlin',
        'kotlin-android',
        'kotlinVersion',
      ],
    );

DeclaredVersion? _findVersion(
  Map<String, String> files,
  List<RegExp> patterns, {
  required List<String> tomlKeys,
}) {
  for (final MapEntry(key: path, value: content) in files.entries) {
    if (path.endsWith('.toml')) {
      final toml = parseVersionCatalog(content);
      for (final key in tomlKeys) {
        final v = parseLooseVersion(toml[key]);
        if (v != null) return (version: v, file: path);
      }
      continue;
    }
    final code = stripGradleComments(content);
    for (final pattern in patterns) {
      final match = pattern.firstMatch(code);
      final v = parseLooseVersion(match?.group(1));
      if (v != null) return (version: v, file: path);
    }
  }
  return null;
}

/// Reads the `[versions]` table of a Gradle version catalog.
Map<String, String> parseVersionCatalog(String content) {
  final result = <String, String>{};
  var inVersions = false;
  final entry = RegExp(r'''^\s*([A-Za-z0-9_.\-]+)\s*=\s*["']([^"']+)["']''');
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      inVersions = trimmed == '[versions]';
      continue;
    }
    if (!inVersions) continue;
    final match = entry.firstMatch(trimmed);
    if (match != null) result[match.group(1)!] = match.group(2)!;
  }
  return result;
}

/// Parses `gradle.properties` (`key=value`, `#` comments).
Map<String, String> parseProperties(String content) {
  final result = <String, String>{};
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    final index = line.indexOf('=');
    if (index <= 0) continue;
    result[line.substring(0, index).trim()] = line.substring(index + 1).trim();
  }
  return result;
}

/// Android settings read from `android/app/build.gradle(.kts)`.
typedef AppModuleInfo = ({
  SdkLevel? compileSdk,
  SdkLevel? minSdk,
  SdkLevel? targetSdk,
  int? javaTarget,
  bool appliesKotlinPlugin,
});

SdkLevel? _sdkLevel(String content, List<String> names) {
  for (final name in names) {
    final match = RegExp(
      '(?:^|[\\s{])$name\\b\\s*(?:=\\s*)?\\(?\\s*([A-Za-z0-9_.]+)',
      multiLine: true,
    ).firstMatch(content);
    if (match == null) continue;
    final value = match.group(1)!;
    final number = int.tryParse(value);
    if (number != null) return SdkLevel.value(number);
    if (value.startsWith('flutter.')) return const SdkLevel.flutterManaged();
  }
  return null;
}

final _javaVersion = RegExp(
  r'(?:sourceCompatibility|targetCompatibility)\s*=?\s*JavaVersion\.VERSION_(?:1_)?(\d+)',
);
final _kotlinPluginApplied = RegExp(
  r'''(?:id\s*\(?\s*["'](?:kotlin-android|org\.jetbrains\.kotlin\.android)["']|apply\s+plugin:\s*["'](?:kotlin-android|org\.jetbrains\.kotlin\.android)["']|kotlin\s*\(\s*["']android["']\s*\))''',
);

/// Parses the app module build file.
AppModuleInfo parseAppModule(String content) {
  final code = stripGradleComments(content);
  final java = _javaVersion.firstMatch(code);
  return (
    compileSdk: _sdkLevel(code, const ['compileSdk', 'compileSdkVersion']),
    minSdk: _sdkLevel(code, const ['minSdk', 'minSdkVersion']),
    targetSdk: _sdkLevel(code, const ['targetSdk', 'targetSdkVersion']),
    javaTarget: java == null ? null : int.parse(java.group(1)!),
    appliesKotlinPlugin: _kotlinPluginApplied.hasMatch(code),
  );
}

/// Removes `//` and `/* */` comments, keeping line structure.
String stripGradleComments(String content) {
  final block = RegExp(r'/\*[\s\S]*?\*/');
  final withoutBlocks = content.replaceAllMapped(
    block,
    (m) => '\n' * '\n'.allMatches(m.group(0)!).length,
  );
  return withoutBlocks.split('\n').map((line) {
    final index = _lineCommentIndex(line);
    return index < 0 ? line : line.substring(0, index);
  }).join('\n');
}

int _lineCommentIndex(String line) {
  String? quote;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '/' && line[i + 1] == '/') {
      // Keep URLs such as https://...
      if (i > 0 && line[i - 1] == ':') continue;
      return i;
    }
  }
  return -1;
}
