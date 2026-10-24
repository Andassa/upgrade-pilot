import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/patch/edit.dart';

/// Sets the Gradle distribution in `gradle-wrapper.properties`, keeping
/// the `bin`/`all` flavour and the host.
Edit setGradleWrapperVersion(String content, Version version) => replaceFirst(
      content,
      RegExp(
        r'(distributionUrl\s*=.*gradle-)([0-9][0-9A-Za-z.\-]*?)(-(?:all|bin)\.zip)',
      ),
      (m) => '${m.group(1)}${gradleDistributionVersion(version)}${m.group(3)}',
    );

String _pluginPattern(String id) =>
    r'''(id\s*\(?\s*["']''' +
    RegExp.escape(id) +
    r'''["']\s*\)?\s*version\s*\(?\s*["'])([^"']+)(["'])''';

Edit _firstDeclaration(String content, List<RegExp> patterns, String value) {
  for (final pattern in patterns) {
    if (!pattern.hasMatch(content)) continue;
    return replaceFirst(
      content,
      pattern,
      (m) => '${m.group(1)}$value${m.group(3)}',
    );
  }
  return unchanged(content, found: false);
}

/// Sets the Android Gradle Plugin version wherever it is declared:
/// plugins block, legacy `classpath`, or version catalog.
Edit setAgpVersion(String content, Version version) => _firstDeclaration(
      content,
      [
        RegExp(_pluginPattern('com.android.application')),
        RegExp(r'''(com\.android\.tools\.build:gradle:)([0-9][^"'\s)]*)()'''),
        RegExp(
          r'''^(\s*(?:agp|android-gradle-plugin|androidGradlePlugin)\s*=\s*["'])([^"']+)(["'])''',
          multiLine: true,
        ),
      ],
      shortVersion(version),
    );

/// Sets the Kotlin Gradle Plugin version (plugins block, `ext.kotlin_version`,
/// legacy classpath or version catalog).
Edit setKotlinVersion(String content, Version version) => _firstDeclaration(
      content,
      [
        RegExp(_pluginPattern('org.jetbrains.kotlin.android')),
        RegExp(r'''(kotlin_version\s*=\s*["'])([^"']+)(["'])'''),
        RegExp(
          r'''(org\.jetbrains\.kotlin:kotlin-gradle-plugin:)([0-9][^"'\s)$]*)()''',
        ),
        RegExp(
          r'''^(\s*(?:kotlin|kotlin-android|kotlinVersion)\s*=\s*["'])([^"']+)(["'])''',
          multiLine: true,
        ),
      ],
      shortVersion(version),
    );

/// Sets `key=value` in a `.properties` file, appending it when absent.
Edit setProperty(String content, String key, String value) {
  final pattern = RegExp(
    '^(\\s*${RegExp.escape(key)}\\s*[=:]\\s*)(.*)\$',
    multiLine: true,
  );
  final match = pattern.firstMatch(content);
  if (match != null) {
    return edited(
      content,
      content.replaceRange(match.start, match.end, '${match.group(1)}$value'),
    );
  }
  final prefix = content.isEmpty || content.endsWith('\n') ? '' : '\n';
  return edited(content, '$content$prefix$key=$value\n');
}

Edit _setSdkLevel(String content, List<String> names, int level) {
  for (final name in names) {
    final pattern = RegExp(
      '^(\\s*$name\\b\\s*(?:=\\s*)?\\(?\\s*)([A-Za-z0-9_.]+)',
      multiLine: true,
    );
    if (pattern.hasMatch(content)) {
      return replaceFirst(content, pattern, (m) => '${m.group(1)}$level');
    }
  }
  return unchanged(content, found: false);
}

/// Sets `minSdk` in the app module build file.
Edit setMinSdk(String content, int level) =>
    _setSdkLevel(content, const ['minSdk', 'minSdkVersion'], level);

/// Sets `compileSdk` in the app module build file.
Edit setCompileSdk(String content, int level) =>
    _setSdkLevel(content, const ['compileSdk', 'compileSdkVersion'], level);

/// Aligns Java `compileOptions` and Kotlin `jvmTarget` on [target].
Edit setJvmTarget(String content, int target) {
  var found = false;
  final constant = target <= 8 ? 'VERSION_1_$target' : 'VERSION_$target';
  var result = content.replaceAllMapped(
    RegExp(
      r'((?:sourceCompatibility|targetCompatibility)\s*=?\s*JavaVersion\.)VERSION_[0-9_]+',
    ),
    (m) {
      found = true;
      return '${m.group(1)}$constant';
    },
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''(jvmTarget\s*=\s*)(JavaVersion\.VERSION_[0-9_]+(\.toString\(\))?|["'][0-9.]+["'])''',
    ),
    (m) {
      found = true;
      final value = m.group(2)!;
      if (value.startsWith('JavaVersion')) {
        return '${m.group(1)}JavaVersion.$constant${m.group(3) ?? ''}';
      }
      return '${m.group(1)}${value[0]}$target${value[0]}';
    },
  );
  result = result.replaceAllMapped(RegExp(r'(JvmTarget\.)JVM_[0-9_]+'), (m) {
    found = true;
    return '${m.group(1)}JVM_${target <= 8 ? '1_$target' : target}';
  });
  return found ? edited(content, result) : unchanged(content, found: false);
}
