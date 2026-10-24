import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

/// A set of changes to try in the sandbox. `null` means "keep the
/// project's value".
@immutable
final class Candidate {
  const Candidate({
    this.gradle,
    this.agp,
    this.kotlin,
    this.gradleProperties = const {},
    this.minSdk,
    this.compileSdk,
    this.jvmTarget,
    this.iosPlatform,
    this.widenSdkFor,
    this.constraints = const {},
    this.depth = 0,
    this.origin = 'project',
  });

  final Version? gradle;
  final Version? agp;
  final Version? kotlin;
  final Map<String, String> gradleProperties;
  final int? minSdk;
  final int? compileSdk;
  final int? jvmTarget;
  final Version? iosPlatform;

  /// Widen `environment.sdk` so that it allows this Dart version.
  final Version? widenSdkFor;

  /// Dependency name → new constraint.
  final Map<String, String> constraints;

  /// Number of automatic fixes applied since an initial candidate.
  final int depth;

  /// Why this candidate exists: `minimal`, `target template`, or a rule id.
  final String origin;

  Candidate copyWith({
    Version? gradle,
    Version? agp,
    Version? kotlin,
    Map<String, String>? gradleProperties,
    int? minSdk,
    int? compileSdk,
    int? jvmTarget,
    Version? iosPlatform,
    Version? widenSdkFor,
    Map<String, String>? constraints,
    int? depth,
    String? origin,
  }) =>
      Candidate(
        gradle: gradle ?? this.gradle,
        agp: agp ?? this.agp,
        kotlin: kotlin ?? this.kotlin,
        gradleProperties: gradleProperties ?? this.gradleProperties,
        minSdk: minSdk ?? this.minSdk,
        compileSdk: compileSdk ?? this.compileSdk,
        jvmTarget: jvmTarget ?? this.jvmTarget,
        iosPlatform: iosPlatform ?? this.iosPlatform,
        widenSdkFor: widenSdkFor ?? this.widenSdkFor,
        constraints: constraints ?? this.constraints,
        depth: depth ?? this.depth,
        origin: origin ?? this.origin,
      );

  /// Adds [extra] constraints; existing ones are kept unless overridden.
  Candidate withConstraints(Map<String, String> extra) =>
      extra.isEmpty ? this : copyWith(constraints: {...constraints, ...extra});

  /// Canonical identity, used to never run the same candidate twice.
  String get key {
    String v(Version? x) => x == null ? '-' : shortVersion(x);
    final props = (gradleProperties.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join(',');
    final deps = (constraints.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}@${e.value}')
        .join(',');
    return [
      v(gradle),
      v(agp),
      v(kotlin),
      props,
      minSdk ?? '-',
      compileSdk ?? '-',
      jvmTarget ?? '-',
      v(iosPlatform),
      v(widenSdkFor),
      deps,
    ].join('|');
  }

  /// Human description of what this candidate changes in [snapshot],
  /// e.g. `AGP 8.1.0 → 9.0.1, Gradle 8.3 → 9.1.0`.
  static String _constraint(ProjectSnapshot snapshot, String name) =>
      snapshot.pubspec.dependency(name)?.constraint ?? 'any';

  List<String> describe(ProjectSnapshot snapshot) {
    final android = snapshot.android;
    String fmt(Version? v) => v == null ? '?' : shortVersion(v);
    String gradleFmt(Version? v) =>
        v == null ? '?' : gradleDistributionVersion(v);
    return [
      if (agp != null && agp != android?.agp)
        'AGP ${fmt(android?.agp)} → ${fmt(agp)}',
      if (gradle != null && gradle != android?.gradle)
        'Gradle ${gradleFmt(android?.gradle)} → ${gradleFmt(gradle)}',
      if (kotlin != null && kotlin != android?.kotlin)
        'Kotlin ${fmt(android?.kotlin)} → ${fmt(kotlin)}',
      for (final MapEntry(:key, :value) in gradleProperties.entries)
        if (android?.gradleProperties[key] != value) '$key=$value',
      if (minSdk != null) 'minSdk → $minSdk',
      if (compileSdk != null) 'compileSdk → $compileSdk',
      if (jvmTarget != null) 'JVM target → $jvmTarget',
      if (iosPlatform != null)
        'iOS ${fmt(snapshot.ios?.deploymentTarget)} → ${fmt(iosPlatform)}',
      if (widenSdkFor != null) 'environment.sdk allows ${fmt(widenSdkFor)}',
      for (final MapEntry(:key, :value) in constraints.entries)
        '$key ${_constraint(snapshot, key)} → $value',
    ];
  }
}
