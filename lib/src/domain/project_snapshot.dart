import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

/// Where a dependency comes from.
enum DependencyKind { hosted, git, path, sdk }

/// A dependency declared in `pubspec.yaml`.
@immutable
final class DependencySpec {
  const DependencySpec({
    required this.name,
    required this.kind,
    this.constraint,
    this.isDev = false,
    this.path,
  });

  final String name;
  final DependencyKind kind;

  /// For path dependencies: the path as written (relative or absolute).
  final String? path;

  /// Version constraint as written, e.g. `^2.1.0`. `null` for `any`,
  /// git, path and sdk dependencies.
  final String? constraint;
  final bool isDev;
}

/// A package resolved in `pubspec.lock`.
@immutable
final class LockedPackage {
  const LockedPackage({
    required this.name,
    required this.version,
    required this.source,
    required this.dependency,
  });

  final String name;
  final String version;

  /// `hosted`, `git`, `path` or `sdk`.
  final String source;

  /// `direct main`, `direct dev`, `direct overridden` or `transitive`.
  final String dependency;
}

/// The content of `pubspec.yaml` that matters for an upgrade.
@immutable
final class PubspecInfo {
  const PubspecInfo({
    required this.name,
    required this.dependencies,
    this.dartConstraint,
    this.flutterConstraint,
    this.hasWorkspace = false,
    this.resolutionWorkspace = false,
  });

  final String name;
  final String? dartConstraint;
  final String? flutterConstraint;
  final List<DependencySpec> dependencies;

  /// The pubspec declares a `workspace:` (monorepo root).
  final bool hasWorkspace;

  /// The pubspec has `resolution: workspace` (monorepo member).
  final bool resolutionWorkspace;

  bool get dependsOnFlutter => dependencies
      .any((d) => d.kind == DependencyKind.sdk && d.name == 'flutter');

  DependencySpec? dependency(String name) {
    for (final d in dependencies) {
      if (d.name == name) return d;
    }
    return null;
  }
}

/// Which file pins the Flutter version of the project.
enum FlutterPinSource { fvmrc, fvmConfig, metadata }

@immutable
final class FlutterPin {
  const FlutterPin({required this.source, this.version, this.revision});

  final FlutterPinSource source;

  /// A version such as `3.24.5`, or a channel such as `stable`.
  final String? version;

  /// The framework revision recorded in `.metadata`.
  final String? revision;
}

/// An Android SDK level. Flutter-managed levels (`flutter.minSdkVersion`)
/// are resolved by the Flutter SDK at build time.
@immutable
final class SdkLevel {
  const SdkLevel.value(int this.value) : flutterManaged = false;
  const SdkLevel.flutterManaged()
      : value = null,
        flutterManaged = true;

  final int? value;
  final bool flutterManaged;

  @override
  String toString() => flutterManaged ? 'flutter-managed' : '$value';
}

/// The Android toolchain declared by the project.
@immutable
final class AndroidConfig {
  const AndroidConfig({
    required this.usesKotlinDsl,
    required this.appliesKotlinPlugin,
    this.gradle,
    this.gradleDistributionType = 'all',
    this.agp,
    this.kotlin,
    this.compileSdk,
    this.minSdk,
    this.targetSdk,
    this.javaTarget,
    this.gradleProperties = const {},
    this.agpDeclaredIn,
    this.kotlinDeclaredIn,
  });

  final Version? gradle;
  final String gradleDistributionType;
  final Version? agp;
  final Version? kotlin;
  final SdkLevel? compileSdk;
  final SdkLevel? minSdk;
  final SdkLevel? targetSdk;

  /// Java language level of `compileOptions`, e.g. 8 or 17.
  final int? javaTarget;
  final bool usesKotlinDsl;

  /// The app module applies the Kotlin Gradle Plugin (`kotlin-android`).
  final bool appliesKotlinPlugin;
  final Map<String, String> gradleProperties;

  /// Relative path of the file declaring AGP, if found.
  final String? agpDeclaredIn;
  final String? kotlinDeclaredIn;
}

/// The iOS configuration declared by the project.
@immutable
final class IosConfig {
  const IosConfig({
    required this.hasPodfile,
    this.podfilePlatform,
    this.xcodeDeploymentTarget,
    this.cocoapodsVersion,
  });

  final bool hasPodfile;
  final Version? podfilePlatform;
  final Version? xcodeDeploymentTarget;
  final String? cocoapodsVersion;

  /// The effective deployment target: the highest declared value.
  Version? get deploymentTarget {
    final a = podfilePlatform;
    final b = xcodeDeploymentTarget;
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }
}

/// Everything upgrade-pilot knows about a project before an upgrade.
@immutable
final class ProjectSnapshot {
  const ProjectSnapshot({
    required this.rootPath,
    required this.pubspec,
    required this.lock,
    this.flutterPin,
    this.android,
    this.ios,
  });

  final String rootPath;
  final PubspecInfo pubspec;
  final Map<String, LockedPackage> lock;
  final FlutterPin? flutterPin;
  final AndroidConfig? android;
  final IosConfig? ios;

  String get name => pubspec.name;
  bool get hasAndroid => android != null;
  bool get hasIos => ios != null;
}
