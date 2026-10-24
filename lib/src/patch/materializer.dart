import 'package:upgrade_pilot/src/analysis/project_inspector.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/patch/edit.dart';
import 'package:upgrade_pilot/src/patch/gradle_patcher.dart';
import 'package:upgrade_pilot/src/patch/ios_patcher.dart';
import 'package:upgrade_pilot/src/patch/pubspec_patcher.dart';

typedef ReadFile = Future<String?> Function(String projectRelative);
typedef WriteFile = Future<void> Function(
  String projectRelative,
  String content,
);

/// Writes a [Candidate] into project files. Returns the edits that could
/// not be applied (declaration not found), so they are reported instead of
/// silently ignored.
final class Materializer {
  const Materializer();

  Future<List<String>> apply(
    Candidate candidate,
    ProjectSnapshot snapshot, {
    required ReadFile read,
    required WriteFile write,
  }) async {
    final skipped = <String>[];
    final pending = <String, String>{};

    Future<void> edit(
      String? path,
      Edit Function(String content) change,
      String label, {
      bool create = false,
    }) async {
      if (path == null) {
        skipped.add('$label: declaration not found');
        return;
      }
      final content = pending[path] ?? await read(path);
      if (content == null && !create) {
        skipped.add('$label: $path not found');
        return;
      }
      final result = change(content ?? '');
      if (!result.found) {
        skipped.add('$label: not declared in $path');
      } else if (result.changed) {
        pending[path] = result.content;
      }
    }

    final android = snapshot.android;
    if (android != null) {
      final appBuild = android.usesKotlinDsl
          ? ProjectFiles.appBuildKts
          : ProjectFiles.appBuildGroovy;
      if (candidate.gradle case final gradle?) {
        await edit(
          ProjectFiles.gradleWrapper,
          (c) => setGradleWrapperVersion(c, gradle),
          'Gradle',
        );
      }
      if (candidate.agp case final agp?) {
        await edit(android.agpDeclaredIn, (c) => setAgpVersion(c, agp), 'AGP');
      }
      if (candidate.kotlin case final kotlin?) {
        await edit(
          android.kotlinDeclaredIn,
          (c) => setKotlinVersion(c, kotlin),
          'Kotlin',
        );
      }
      for (final MapEntry(:key, :value) in candidate.gradleProperties.entries) {
        await edit(
          ProjectFiles.gradleProperties,
          (c) => setProperty(c, key, value),
          key,
          create: true,
        );
      }
      if (candidate.minSdk case final level?) {
        await edit(appBuild, (c) => setMinSdk(c, level), 'minSdk');
      }
      if (candidate.compileSdk case final level?) {
        await edit(appBuild, (c) => setCompileSdk(c, level), 'compileSdk');
      }
      if (candidate.jvmTarget case final target?) {
        await edit(appBuild, (c) => setJvmTarget(c, target), 'JVM target');
      }
    }
    if (candidate.iosPlatform case final ios? when snapshot.ios != null) {
      if (snapshot.ios!.hasPodfile) {
        await edit(
          ProjectFiles.podfile,
          (c) => setPodfilePlatform(c, ios),
          'iOS platform',
        );
      }
      await edit(
        ProjectFiles.pbxproj,
        (c) => raiseXcodeDeploymentTarget(c, ios),
        'IPHONEOS_DEPLOYMENT_TARGET',
      );
    }
    if (candidate.widenSdkFor case final dart?) {
      await edit(
        ProjectFiles.pubspec,
        (c) => widenSdkConstraint(c, dart),
        'environment.sdk',
      );
    }
    for (final MapEntry(:key, :value) in candidate.constraints.entries) {
      await edit(
        ProjectFiles.pubspec,
        (c) => setDependencyConstraint(c, key, value),
        key,
      );
    }
    for (final MapEntry(:key, :value) in pending.entries) {
      await write(key, value);
    }
    return skipped;
  }
}
