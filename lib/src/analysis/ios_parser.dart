import 'package:pub_semver/pub_semver.dart';

import 'package:upgrade_pilot/src/domain/versions.dart';

final _platform = RegExp(
  r'''^\s*platform\s+:ios\s*,\s*["']([0-9.]+)["']''',
  multiLine: true,
);

/// Reads `platform :ios, 'X'` from a Podfile. Commented lines are ignored.
Version? parsePodfilePlatform(String content) =>
    parseLooseVersion(_platform.firstMatch(content)?.group(1));

final _deploymentTarget = RegExp(
  r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*"?([0-9.]+)"?\s*;',
);

/// Highest `IPHONEOS_DEPLOYMENT_TARGET` in an Xcode `project.pbxproj`.
Version? parseXcodeDeploymentTarget(String content) => maxVersion(
      _deploymentTarget
          .allMatches(content)
          .map((m) => parseLooseVersion(m.group(1))),
    );

final _cocoapods = RegExp(r'^COCOAPODS:\s*([0-9.]+)', multiLine: true);

/// CocoaPods version recorded in `Podfile.lock`.
String? parsePodfileLockCocoapods(String content) =>
    _cocoapods.firstMatch(content)?.group(1);
