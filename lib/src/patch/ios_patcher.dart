import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/patch/edit.dart';

String _iosVersion(Version v) => '${v.major}.${v.minor}';

/// Sets `platform :ios, 'X'` in a Podfile, uncommenting the line Flutter
/// templates ship commented out.
Edit setPodfilePlatform(String content, Version version) => replaceFirst(
      content,
      RegExp(
        r'''^(\s*)#?\s*(platform\s+:ios\s*,\s*["'])([0-9.]+)(["'])''',
        multiLine: true,
      ),
      (m) => '${m.group(1)}${m.group(2)}${_iosVersion(version)}${m.group(4)}',
    );

/// Raises every `IPHONEOS_DEPLOYMENT_TARGET` lower than [version].
Edit raiseXcodeDeploymentTarget(String content, Version version) {
  var found = false;
  final floor = Version(version.major, version.minor, 0);
  final result = content.replaceAllMapped(
    RegExp(r'(IPHONEOS_DEPLOYMENT_TARGET\s*=\s*)([0-9.]+)(\s*;)'),
    (m) {
      found = true;
      final current = parseLooseVersion(m.group(2));
      if (current == null || current >= floor) return m.group(0)!;
      return '${m.group(1)}${_iosVersion(version)}${m.group(3)}';
    },
  );
  return found ? edited(content, result) : unchanged(content, found: false);
}
