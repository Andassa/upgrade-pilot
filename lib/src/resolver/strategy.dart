import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/resolver/pub_dev.dart';

/// Everything the strategy needs to reason about a target.
@immutable
final class StrategyContext {
  const StrategyContext({
    required this.snapshot,
    required this.kb,
    required this.flutter,
    required this.dart,
    this.jdkMajor,
  });

  final ProjectSnapshot snapshot;
  final KnowledgeBase kb;

  /// Target Flutter and Dart versions.
  final Version flutter;
  final Version dart;

  /// JDK used by Flutter for Gradle, when known.
  final int? jdkMajor;

  FlutterToolchain? get toolchain => kb.forFlutter(flutter);
}

/// Outcome of turning a diagnosis into a next step.
sealed class FixResult {
  const FixResult();
}

final class NextCandidate extends FixResult {
  const NextCandidate(this.candidate, {this.dependencyConstraints = const {}});

  final Candidate candidate;

  /// Dependency fixes, valid for every later candidate.
  final Map<String, String> dependencyConstraints;
}

final class Blocked extends FixResult {
  const Blocked(this.item);

  final BlockedItem item;
}

final class NoFix extends FixResult {
  const NoFix();
}

/// Builds initial candidates from the knowledge base and turns diagnoses
/// into new candidates.
final class Strategy {
  Strategy(this.context, this._pub);

  final StrategyContext context;
  final PubDevClient _pub;

  ProjectSnapshot get _snapshot => context.snapshot;
  AndroidConfig? get _android => _snapshot.android;

  /// Gradle properties AGP 9 needs when the project still applies the
  /// Kotlin Gradle Plugin (as set by the target Flutter template).
  Map<String, String> _agp9Properties(Version? agp) {
    final android = _android;
    final template = context.toolchain?.templateGradleProperties ?? const {};
    if (android == null || agp == null || agp.major < 9) return const {};
    if ((android.agp?.major ?? 0) >= 9) return const {};
    return {
      for (final MapEntry(:key, :value) in template.entries)
        if (!android.gradleProperties.containsKey(key)) key: value,
    };
  }

  Version? _gradleFloor(Version? agp) {
    final range = context.jdkMajor == null
        ? null
        : context.kb.gradleRangeForJava(context.jdkMajor!);
    return maxVersion([
      if (agp != null) context.kb.minGradleForAgp(agp),
      range?.min,
    ]);
  }

  Candidate _build({
    required String origin,
    Version? agp,
    Version? gradle,
    Version? kotlin,
  }) {
    final android = _android!;
    final newAgp = maxVersion([android.agp, agp]);
    final newGradle =
        maxVersion([android.gradle, gradle, _gradleFloor(newAgp)]);
    final newKotlin =
        android.kotlin == null ? null : maxVersion([android.kotlin, kotlin]);
    return Candidate(
      agp: android.agp == null || newAgp == android.agp ? null : newAgp,
      gradle: newGradle == android.gradle ? null : newGradle,
      kotlin: newKotlin == android.kotlin ? null : newKotlin,
      gradleProperties: _agp9Properties(newAgp),
      origin: origin,
    );
  }

  /// The minimal toolchain Flutter accepts without warnings, then the
  /// toolchain of the target Flutter template. Unknown values are left
  /// unchanged and settled by the build.
  List<Candidate> initialCandidates() {
    if (_android == null) return const [Candidate(origin: 'minimal')];
    final toolchain = context.toolchain;
    final minimal = _build(
      origin: 'minimal',
      agp: toolchain?.agp.warn,
      gradle: toolchain?.gradle.warn,
      kotlin: toolchain?.kotlin.warn,
    );
    final result = [minimal];
    if (toolchain?.templateAgp != null) {
      final template = _build(
        origin: 'target template',
        agp: toolchain!.templateAgp,
        gradle: toolchain.templateGradle,
        kotlin: toolchain.templateKotlin,
      );
      if (template.key != minimal.key) result.add(template);
    }
    return result;
  }

  Version? _capturedVersion(Diagnosis d, String name) =>
      parseLooseVersion(d.finding.captures[name]);

  int? _capturedInt(Diagnosis d, String name) =>
      int.tryParse(d.finding.captures[name] ?? '');

  Version? _effective(Version? candidate, Version? project) =>
      candidate ?? project;

  /// Derives the next candidate from [diagnosis], or explains why the
  /// problem is blocked.
  Future<FixResult> fix(Candidate current, Diagnosis diagnosis) async {
    final android = _android;
    final toolchain = context.toolchain;
    final next = current.copyWith(
      depth: current.depth + 1,
      origin: diagnosis.finding.id,
    );
    Candidate withAgp(Version agp) {
      final gradle = maxVersion([
        _effective(current.gradle, android?.gradle),
        _gradleFloor(agp),
      ]);
      return next.copyWith(
        agp: agp,
        gradle: gradle,
        gradleProperties: {
          ...current.gradleProperties,
          ..._agp9Properties(agp),
        },
      );
    }

    FixResult changed(Candidate candidate) =>
        candidate.key == current.key ? const NoFix() : NextCandidate(candidate);

    switch (diagnosis.action) {
      case FixAction.none:
        return const NoFix();
      case FixAction.setConstraint:
        final package = diagnosis.finding.captures['package'];
        final constraint = diagnosis.finding.captures['constraint'];
        if (package == null || constraint == null) return const NoFix();
        if (current.constraints[package] == constraint) return const NoFix();
        return NextCandidate(
          next.withConstraints({package: constraint}),
          dependencyConstraints: {package: constraint},
        );
      case FixAction.upgradeDependency:
        return _upgradeDependency(current, next, diagnosis);
      case FixAction.widenSdkConstraint:
        if (current.widenSdkFor != null) return const NoFix();
        return changed(next.copyWith(widenSdkFor: context.dart));
      case FixAction.gradleForJdk:
        final major = _capturedInt(diagnosis, 'java') ??
            switch (_capturedInt(diagnosis, 'major')) {
              final classMajor? => classMajor - 44,
              null => context.jdkMajor,
            };
        if (major == null) return const NoFix();
        final range = context.kb.gradleRangeForJava(major);
        if (range == null) return const NoFix();
        final gradle = maxVersion([
          _effective(current.gradle, android?.gradle),
          range.min,
        ])!;
        return changed(next.copyWith(gradle: gradle));
      case FixAction.bumpAgp:
        final floor = maxVersion([
          _capturedVersion(diagnosis, 'min'),
          toolchain?.agp.warn,
        ]);
        final agp = maxVersion([
          _effective(current.agp, android?.agp),
          floor ?? toolchain?.templateAgp,
        ]);
        if (agp == null) return const NoFix();
        return changed(withAgp(agp));
      case FixAction.bumpAgpForCompileSdk:
        final api = current.compileSdk ??
            android?.compileSdk?.value ??
            toolchain?.compileSdk;
        final min = api == null ? null : context.kb.minAgpForCompileSdk(api);
        if (min == null) return const NoFix();
        final agp = maxVersion([_effective(current.agp, android?.agp), min])!;
        return changed(withAgp(agp));
      case FixAction.bumpGradle:
        final min = _capturedVersion(diagnosis, 'min') ??
            toolchain?.templateGradle ??
            toolchain?.gradle.warn;
        if (min == null) return const NoFix();
        final gradle = maxVersion([
          _effective(current.gradle, android?.gradle),
          min,
        ])!;
        return changed(next.copyWith(gradle: gradle));
      case FixAction.bumpKotlin:
        if (android?.kotlin == null) return const NoFix();
        final min = maxVersion([
          _capturedVersion(diagnosis, 'min'),
          toolchain?.kotlin.warn,
        ]);
        final kotlin = maxVersion([
          _effective(current.kotlin, android?.kotlin),
          min ?? toolchain?.templateKotlin,
        ]);
        if (kotlin == null) return const NoFix();
        return changed(next.copyWith(kotlin: kotlin));
      case FixAction.disableBuiltInKotlin:
        return changed(
          next.copyWith(
            gradleProperties: {
              ...current.gradleProperties,
              'android.builtInKotlin': 'false',
            },
          ),
        );
      case FixAction.disableNewDsl:
        return changed(
          next.copyWith(
            gradleProperties: {
              ...current.gradleProperties,
              'android.newDsl': 'false',
            },
          ),
        );
      case FixAction.setMinSdk:
        final min = _capturedInt(diagnosis, 'min');
        if (min == null) return const NoFix();
        return changed(next.copyWith(minSdk: min));
      case FixAction.setCompileSdk:
        final min = _capturedInt(diagnosis, 'min');
        if (min == null) return const NoFix();
        return changed(next.copyWith(compileSdk: min));
      case FixAction.normalizeGradleDistribution:
        final version = _capturedVersion(diagnosis, 'version') ??
            _effective(current.gradle, android?.gradle);
        if (version == null) return const NoFix();
        // Writing the version again uses the published distribution name.
        return NextCandidate(next.copyWith(gradle: version));
      case FixAction.alignJvmTarget:
        if (current.jvmTarget == 17) return const NoFix();
        return NextCandidate(next.copyWith(jvmTarget: 17));
      case FixAction.setIosDeploymentTarget:
        final target = toolchain?.iosTemplatePlatform;
        final currentTarget =
            current.iosPlatform ?? _snapshot.ios?.deploymentTarget;
        if (target == null ||
            (currentTarget != null && currentTarget >= target)) {
          return const NoFix();
        }
        return changed(next.copyWith(iosPlatform: target));
    }
  }

  Future<FixResult> _upgradeDependency(
    Candidate current,
    Candidate next,
    Diagnosis diagnosis,
  ) async {
    final package = diagnosis.finding.captures['package'];
    if (package == null) return const NoFix();
    final declared = _snapshot.pubspec.dependency(package);
    final locked = _snapshot.lock[package]?.version;
    final subject = '$package ${locked ?? declared?.constraint ?? ''}'.trim();
    if (declared == null) {
      return Blocked(
        BlockedItem(
          subject: subject,
          reason: 'Transitive dependency: upgrade the direct dependency that '
              'requires it.',
          findingId: diagnosis.finding.id,
        ),
      );
    }
    if (declared.kind != DependencyKind.hosted) {
      return Blocked(
        BlockedItem(
          subject: subject,
          reason: 'Not a pub.dev dependency (${declared.kind.name}); '
              'update it by hand.',
          findingId: diagnosis.finding.id,
        ),
      );
    }
    final latest = await _pub.latestCompatible(
      package,
      dart: context.dart,
      flutter: context.flutter,
    );
    if (latest == null) {
      final info = await _pub.package(package);
      final dart = shortVersion(context.dart);
      final flutter = shortVersion(context.flutter);
      return Blocked(
        BlockedItem(
          subject: subject,
          reason: info == null
              ? 'pub.dev metadata unavailable; no compatible version could '
                  'be checked.'
              : 'No published version supports Dart $dart and Flutter '
                  '$flutter${info.discontinued ? ' (discontinued)' : ''}.',
          suggestion: info?.replacedBy == null
              ? null
              : '${info!.replacedBy} (replacement named on pub.dev)',
          findingId: diagnosis.finding.id,
        ),
      );
    }
    final constraint = '^${shortVersion(latest)}';
    final lockedVersion = parseLooseVersion(locked);
    final alreadyLatest = lockedVersion != null
        ? lockedVersion == latest
        : declared.constraint != null && _allows(declared.constraint!, latest);
    if (current.constraints[package] == constraint ||
        (alreadyLatest && !current.constraints.containsKey(package))) {
      return Blocked(
        BlockedItem(
          subject: subject,
          reason:
              'The newest compatible version (${shortVersion(latest)}) still '
              'fails with the target Flutter version.',
          findingId: diagnosis.finding.id,
        ),
      );
    }
    return NextCandidate(
      next.withConstraints({package: constraint}),
      dependencyConstraints: {package: constraint},
    );
  }

  static bool _allows(String constraint, Version version) {
    try {
      return VersionConstraint.parse(constraint).allows(version);
    } on FormatException {
      return false;
    }
  }
}
