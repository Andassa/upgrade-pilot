import 'package:upgrade_pilot/src/analysis/gradle_parser.dart';
import 'package:upgrade_pilot/src/analysis/ios_parser.dart';
import 'package:upgrade_pilot/src/analysis/pubspec_parser.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/patch/diff.dart';
import 'package:upgrade_pilot/src/sandbox/copy_policy.dart';

/// Turns a before/after pair into a [Change]: summary, checksums,
/// zero-context hunks and a redacted diff. Full contents are not kept.
Change describeChange(
  String path,
  String? before,
  String after, {
  required Redactor redactor,
}) {
  final kind = _kind(path);
  return Change(
    path: path,
    kind: kind,
    summary: _summary(kind, path, before, after),
    beforeSha256: before == null ? null : sha256Hex(before),
    afterSha256: sha256Hex(after),
    hunks: computeHunks(before, after),
    diff: redactor.redact(unifiedDiff(path, before, after)),
    generated: CopyPolicy.isGenerated(path),
  );
}

ChangeKind _kind(String path) {
  final name = path.split('/').last;
  if (name == 'pubspec.yaml') return ChangeKind.pubspec;
  if (name == 'pubspec.lock' || name == 'Podfile.lock') {
    return ChangeKind.lockfile;
  }
  if (name == 'gradle-wrapper.properties') return ChangeKind.gradleWrapper;
  if (name == 'gradle.properties') return ChangeKind.gradleProperties;
  if (name.startsWith('settings.gradle')) return ChangeKind.gradleSettings;
  if (name.endsWith('.toml')) return ChangeKind.versionCatalog;
  if (name.endsWith('.gradle') || name.endsWith('.gradle.kts')) {
    return ChangeKind.gradleBuild;
  }
  if (name == 'Podfile') return ChangeKind.podfile;
  if (name == '.fvmrc' || name == 'fvm_config.json') {
    return ChangeKind.flutterPin;
  }
  return ChangeKind.xcodeProject;
}

String _arrow(Object? from, Object? to) => '${from ?? 'none'} → $to';

String _summary(ChangeKind kind, String path, String? before, String after) {
  final old = before ?? '';
  final parts = <String>[];
  switch (kind) {
    case ChangeKind.gradleWrapper:
      final a = parseGradleWrapper(old)?.version;
      final b = parseGradleWrapper(after)?.version;
      if (b != null && a != b) {
        final from = a == null ? null : gradleDistributionVersion(a);
        parts.add('Gradle ${_arrow(from, gradleDistributionVersion(b))}');
      }
    case ChangeKind.gradleSettings ||
          ChangeKind.gradleBuild ||
          ChangeKind.versionCatalog:
      final agpA = findAgpVersion({path: old})?.version;
      final agpB = findAgpVersion({path: after})?.version;
      if (agpB != null && agpA != agpB) {
        final from = agpA == null ? null : shortVersion(agpA);
        parts.add('AGP ${_arrow(from, shortVersion(agpB))}');
      }
      final ktA = findKotlinVersion({path: old})?.version;
      final ktB = findKotlinVersion({path: after})?.version;
      if (ktB != null && ktA != ktB) {
        final from = ktA == null ? null : shortVersion(ktA);
        parts.add('Kotlin ${_arrow(from, shortVersion(ktB))}');
      }
      if (path.contains('/app/')) {
        final a = parseAppModule(old);
        final b = parseAppModule(after);
        if ('${a.minSdk}' != '${b.minSdk}') {
          parts.add('minSdk ${_arrow(a.minSdk, b.minSdk)}');
        }
        if ('${a.compileSdk}' != '${b.compileSdk}') {
          parts.add('compileSdk ${_arrow(a.compileSdk, b.compileSdk)}');
        }
        if (a.javaTarget != b.javaTarget) {
          parts.add('Java target ${_arrow(a.javaTarget, b.javaTarget)}');
        }
      }
    case ChangeKind.gradleProperties:
      final a = parseProperties(old);
      final b = parseProperties(after);
      for (final MapEntry(:key, :value) in b.entries) {
        if (a[key] != value) parts.add('$key=$value');
      }
    case ChangeKind.pubspec:
      try {
        final a = parsePubspec(old);
        final b = parsePubspec(after);
        if (a.dartConstraint != b.dartConstraint) {
          parts.add('sdk ${_arrow(a.dartConstraint, b.dartConstraint)}');
        }
        for (final dep in b.dependencies) {
          final previous = a.dependency(dep.name)?.constraint;
          if (previous != dep.constraint) {
            parts.add('${dep.name} ${_arrow(previous, dep.constraint)}');
          }
        }
      } on ManifestException {
        break;
      }
    case ChangeKind.lockfile:
      if (path.endsWith('pubspec.lock')) {
        final a = parsePubspecLock(old);
        final b = parsePubspecLock(after);
        final changed =
            b.entries.where((e) => a[e.key]?.version != e.value.version).length;
        parts.add(
          before == null
              ? 'created by pub get'
              : '$changed ${changed == 1 ? 'package' : 'packages'} re-resolved',
        );
      } else {
        parts.add('updated by pod install');
      }
    case ChangeKind.podfile:
      final a = parsePodfilePlatform(old);
      final b = parsePodfilePlatform(after);
      if (b != null && a != b) parts.add('iOS ${_arrow(a, b)}');
    case ChangeKind.xcodeProject:
      if (path.endsWith('.pbxproj')) {
        final a = parseXcodeDeploymentTarget(old);
        final b = parseXcodeDeploymentTarget(after);
        if (b != null && a != b) {
          parts.add('IPHONEOS_DEPLOYMENT_TARGET ${_arrow(a, b)}');
        }
      }
    case ChangeKind.flutterPin:
      parts.add('Flutter version pin');
  }
  return parts.isEmpty
      ? 'migrated by the Flutter tool during the build'
      : parts.join(', ');
}

/// Lock-level changes of direct dependencies.
typedef DependencyMove = ({
  String name,
  String? fromConstraint,
  String? toConstraint,
  String? fromVersion,
  String? toVersion,
});

List<DependencyMove> dependencyMoves(
  ProjectSnapshot snapshot, {
  String? newPubspec,
  String? newLock,
}) {
  final pubspec =
      newPubspec == null ? snapshot.pubspec : parsePubspec(newPubspec);
  final lock = newLock == null ? snapshot.lock : parsePubspecLock(newLock);
  final result = <DependencyMove>[];
  for (final dep in pubspec.dependencies) {
    if (dep.kind == DependencyKind.sdk) continue;
    final fromConstraint = snapshot.pubspec.dependency(dep.name)?.constraint;
    final fromVersion = snapshot.lock[dep.name]?.version;
    final toVersion = lock[dep.name]?.version;
    // Without a previous lock file, a resolved version is not an update.
    final versionMoved = fromVersion != null && fromVersion != toVersion;
    if (fromConstraint != dep.constraint || versionMoved) {
      result.add(
        (
          name: dep.name,
          fromConstraint: fromConstraint,
          toConstraint: dep.constraint,
          fromVersion: fromVersion,
          toVersion: toVersion,
        ),
      );
    }
  }
  return result;
}
