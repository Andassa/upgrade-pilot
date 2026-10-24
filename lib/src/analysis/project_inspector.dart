import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/analysis/gradle_parser.dart';
import 'package:upgrade_pilot/src/analysis/ios_parser.dart';
import 'package:upgrade_pilot/src/analysis/metadata_parser.dart';
import 'package:upgrade_pilot/src/analysis/pubspec_parser.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Gradle and iOS files that may be read or changed, relative to the root.
abstract final class ProjectFiles {
  static const pubspec = 'pubspec.yaml';
  static const lock = 'pubspec.lock';
  static const metadata = '.metadata';
  static const fvmrc = '.fvmrc';
  static const fvmConfig = '.fvm/fvm_config.json';
  static const gradleWrapper =
      'android/gradle/wrapper/gradle-wrapper.properties';
  static const gradleProperties = 'android/gradle.properties';
  static const versionCatalog = 'android/gradle/libs.versions.toml';
  static const settingsKts = 'android/settings.gradle.kts';
  static const settingsGroovy = 'android/settings.gradle';
  static const rootBuildKts = 'android/build.gradle.kts';
  static const rootBuildGroovy = 'android/build.gradle';
  static const appBuildKts = 'android/app/build.gradle.kts';
  static const appBuildGroovy = 'android/app/build.gradle';
  static const podfile = 'ios/Podfile';
  static const podfileLock = 'ios/Podfile.lock';
  static const pbxproj = 'ios/Runner.xcodeproj/project.pbxproj';

  /// Files whose content defines the project fingerprint.
  static const List<String> fingerprinted = [
    pubspec,
    lock,
    fvmrc,
    fvmConfig,
    gradleWrapper,
    gradleProperties,
    versionCatalog,
    settingsKts,
    settingsGroovy,
    rootBuildKts,
    rootBuildGroovy,
    appBuildKts,
    appBuildGroovy,
    podfile,
    pbxproj,
  ];
}

/// Thrown when the directory is not a Flutter application.
final class NotAFlutterProjectException implements Exception {
  NotAFlutterProjectException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => '$path: $reason';
}

/// Reads a project from disk and builds a [ProjectSnapshot]. Read-only.
final class ProjectInspector {
  ProjectInspector(this._fs);

  final FileSystem _fs;

  Future<String?> _read(String root, String relative) =>
      _fs.readString(p.joinAll([root, ...relative.split('/')]));

  Future<ProjectSnapshot> inspect(String root) async {
    final pubspecText = await _read(root, ProjectFiles.pubspec);
    if (pubspecText == null) {
      throw NotAFlutterProjectException(root, 'no pubspec.yaml found');
    }
    final pubspec = parsePubspec(pubspecText);
    if (!pubspec.dependsOnFlutter) {
      throw NotAFlutterProjectException(
        root,
        'pubspec.yaml does not depend on the Flutter SDK',
      );
    }
    final lockText = await _read(root, ProjectFiles.lock);
    return ProjectSnapshot(
      rootPath: root,
      pubspec: pubspec,
      lock: lockText == null ? const {} : parsePubspecLock(lockText),
      flutterPin: await _flutterPin(root),
      android: await _android(root),
      ios: await _ios(root),
    );
  }

  Future<FlutterPin?> _flutterPin(String root) async {
    final fvmrc = await _read(root, ProjectFiles.fvmrc);
    final fromFvmrc = fvmrc == null ? null : parseFvmrc(fvmrc);
    if (fromFvmrc != null) return fromFvmrc;
    final fvmConfig = await _read(root, ProjectFiles.fvmConfig);
    final fromConfig = fvmConfig == null ? null : parseFvmConfig(fvmConfig);
    if (fromConfig != null) return fromConfig;
    final metadata = await _read(root, ProjectFiles.metadata);
    return metadata == null ? null : parseMetadata(metadata);
  }

  Future<AndroidConfig?> _android(String root) async {
    if (!await _fs.isDirectory(p.join(root, 'android'))) return null;
    final files = <String, String>{};
    for (final path in const [
      ProjectFiles.settingsKts,
      ProjectFiles.settingsGroovy,
      ProjectFiles.rootBuildKts,
      ProjectFiles.rootBuildGroovy,
      ProjectFiles.versionCatalog,
    ]) {
      final content = await _read(root, path);
      if (content != null) files[path] = content;
    }
    final wrapperText = await _read(root, ProjectFiles.gradleWrapper);
    final wrapper =
        wrapperText == null ? null : parseGradleWrapper(wrapperText);
    final appKts = await _read(root, ProjectFiles.appBuildKts);
    final appText = appKts ?? await _read(root, ProjectFiles.appBuildGroovy);
    final app = appText == null ? null : parseAppModule(appText);
    final propertiesText = await _read(root, ProjectFiles.gradleProperties);
    final agp = findAgpVersion(files);
    final kotlin = findKotlinVersion(files);
    return AndroidConfig(
      gradle: wrapper?.version,
      gradleDistributionType: wrapper?.type ?? 'all',
      agp: agp?.version,
      agpDeclaredIn: agp?.file,
      kotlin: kotlin?.version,
      kotlinDeclaredIn: kotlin?.file,
      compileSdk: app?.compileSdk,
      minSdk: app?.minSdk,
      targetSdk: app?.targetSdk,
      javaTarget: app?.javaTarget,
      usesKotlinDsl: appKts != null,
      appliesKotlinPlugin: app?.appliesKotlinPlugin ?? false,
      gradleProperties:
          propertiesText == null ? const {} : parseProperties(propertiesText),
    );
  }

  Future<IosConfig?> _ios(String root) async {
    if (!await _fs.isDirectory(p.join(root, 'ios'))) return null;
    final podfile = await _read(root, ProjectFiles.podfile);
    final podfileLock = await _read(root, ProjectFiles.podfileLock);
    final pbxproj = await _read(root, ProjectFiles.pbxproj);
    return IosConfig(
      hasPodfile: podfile != null,
      podfilePlatform: podfile == null ? null : parsePodfilePlatform(podfile),
      xcodeDeploymentTarget:
          pbxproj == null ? null : parseXcodeDeploymentTarget(pbxproj),
      cocoapodsVersion:
          podfileLock == null ? null : parsePodfileLockCocoapods(podfileLock),
    );
  }
}
