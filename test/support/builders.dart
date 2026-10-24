import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/release.dart';

/// Absolute path of a fixture project.
String fixture(String name) =>
    p.join(Directory.current.path, 'test', 'fixtures', name);

/// The Flutter 3.24-era project of `test/fixtures/legacy_toolchain`.
ProjectSnapshot legacySnapshot({
  Map<String, LockedPackage> lock = const {},
  Map<String, String> gradleProperties = const {
    'android.useAndroidX': 'true',
  },
}) =>
    ProjectSnapshot(
      rootPath: '/work/legacy',
      pubspec: const PubspecInfo(
        name: 'legacy_app',
        dartConstraint: '^3.5.4',
        dependencies: [
          DependencySpec(name: 'flutter', kind: DependencyKind.sdk),
          DependencySpec(
            name: 'http',
            kind: DependencyKind.hosted,
            constraint: '^0.12.2',
          ),
          DependencySpec(
            name: 'local_pkg',
            kind: DependencyKind.path,
            path: '../local_pkg',
          ),
        ],
      ),
      lock: lock,
      android: AndroidConfig(
        usesKotlinDsl: false,
        appliesKotlinPlugin: true,
        gradle: Version(8, 3, 0),
        agp: Version(8, 1, 0),
        agpDeclaredIn: 'android/settings.gradle',
        kotlin: Version(1, 8, 22),
        kotlinDeclaredIn: 'android/settings.gradle',
        compileSdk: const SdkLevel.flutterManaged(),
        minSdk: const SdkLevel.flutterManaged(),
        javaTarget: 8,
        gradleProperties: gradleProperties,
      ),
      ios: const IosConfig(hasPodfile: false),
    );

FlutterRelease release({
  String version = '3.44.9',
  String dart = '3.12.2',
  String channel = 'stable',
}) =>
    FlutterRelease(
      version: Version.parse(version),
      channel: channel,
      hash: 'abc123',
      releaseDate: DateTime.utc(2026, 8, 6),
      dartVersion: Version.parse(dart),
      archive: 'stable/linux/flutter_linux_$version-stable.tar.xz',
      sha256: 'f' * 64,
    );

Plan samplePlan({Verdict verdict = Verdict.verified}) => Plan(
      toolVersion: '1.0.0',
      kbVersion: '2026.10.24',
      createdAt: DateTime.utc(2026, 10, 24, 9),
      project: const PlanProject(
        name: 'legacy_app',
        displayPath: '~/apps/legacy_app',
        fingerprint: 'fp',
        gitCommit: '0123456789abcdef',
        flutterVersion: '3.24.5',
      ),
      target: release(),
      sdkSource: 'global',
      platforms: const ['android', 'ios'],
      changes: const [
        Change(
          path: 'android/settings.gradle',
          kind: ChangeKind.gradleSettings,
          summary: 'AGP 8.1.0 → 8.11.1, Kotlin 1.8.22 → 2.2.20',
          beforeSha256: 'b1',
          afterSha256: 'a1',
          hunks: [
            Hunk(
              start: 20,
              deleteCount: 1,
              insert: ['    id "x" version "8.11.1"'],
            ),
          ],
          diff: '--- a/android/settings.gradle\n+++ b/android/settings.gradle\n'
              '@@ -21,1 +21,1 @@\n-    id "x" version "8.1.0"\n'
              '+    id "x" version "8.11.1"\n',
        ),
        Change(
          path: 'pubspec.lock',
          kind: ChangeKind.lockfile,
          summary: '3 packages re-resolved',
          beforeSha256: 'b2',
          afterSha256: 'a2',
          hunks: [],
          diff: '',
          generated: true,
        ),
      ],
      manualSteps: const [
        ManualStep(
          title: 'Switch your Flutter SDK to 3.44.9',
          command: 'flutter upgrade',
        ),
      ],
      dependencyUpdates: const [
        DependencyUpdate(
          name: 'http',
          fromConstraint: '^0.12.2',
          toConstraint: '^1.6.0',
          fromVersion: '0.12.2',
          toVersion: '1.6.0',
        ),
      ],
      blocked: verdict == Verdict.blocked
          ? const [
              BlockedItem(
                subject: 'progress_dialog 1.2.4',
                reason: 'No published version supports Dart 3.12.2.',
                suggestion: 'other_dialog (replacement named on pub.dev)',
                findingId: 'UP-PUB-0001',
              ),
            ]
          : const [],
      evidence: [
        const Evidence(
          step: 'pub get',
          command: 'flutter pub get',
          status: StepStatus.failed,
          duration: Duration(milliseconds: 5200),
          attempt: 1,
          exitCode: 1,
          detail: 'UP-PUB-0002',
          excerpt: 'Try upgrading your constraint on http',
          findingId: 'UP-PUB-0002',
        ),
        const Evidence(
          step: 'pub get',
          command: 'flutter pub get',
          status: StepStatus.ok,
          duration: Duration(milliseconds: 9800),
          attempt: 2,
          exitCode: 0,
        ),
        const Evidence(
          step: 'analyze',
          command: 'flutter analyze --no-fatal-infos --no-fatal-warnings',
          status: StepStatus.warning,
          duration: Duration(milliseconds: 14200),
          attempt: 2,
          exitCode: 0,
          detail: '3 warnings',
        ),
        Evidence(
          step: 'build apk',
          command: 'flutter build apk --debug',
          status:
              verdict == Verdict.blocked ? StepStatus.failed : StepStatus.ok,
          duration: const Duration(seconds: 98),
          attempt: 2,
          exitCode: verdict == Verdict.blocked ? 1 : 0,
        ),
      ],
      attempts: [
        const AttemptRecord(
          number: 1,
          description: 'AGP 8.1.0 → 8.11.1',
          succeeded: false,
          findingId: 'UP-PUB-0002',
        ),
        AttemptRecord(
          number: 2,
          description: 'AGP 8.1.0 → 8.11.1, http ^0.12.2 → ^1.6.0',
          succeeded: verdict != Verdict.blocked,
          findingId: verdict == Verdict.blocked ? 'UP-PUB-0001' : null,
        ),
      ],
      findings: const [
        Finding(
          id: 'UP-PUB-0002',
          title: 'pub suggests a newer constraint',
          cause: 'The constraint on http only allows old versions.',
          fix: 'Change the constraint on http to ^1.6.0.',
          confidence: Confidence.high,
          step: 'pub get',
          docsUrl: 'https://dart.dev/tools/pub/troubleshoot',
          excerpt: 'Try upgrading your constraint on http: flutter pub add '
              'http:^1.6.0',
          captures: {'package': 'http', 'constraint': '^1.6.0'},
        ),
        Finding(
          id: 'UP-PUB-0001',
          title: 'Dependency without null safety',
          cause: 'progress_dialog predates null safety.',
          fix: 'Upgrade progress_dialog.',
          confidence: Confidence.high,
          step: 'pub get',
          docsUrl: 'https://dart.dev/null-safety',
          excerpt:
              "Because app depends on progress_dialog which doesn't support "
              'null safety',
        ),
      ],
      notVerified: const [
        NotVerified(what: 'iOS build', reason: 'Xcode not available'),
        NotVerified(what: 'Tests', reason: 'not run (use --run-tests)'),
        NotVerified(
          what: 'Runtime behaviour',
          reason:
              'a successful build does not prove that the app behaves the same',
        ),
      ],
      verdict: verdict,
      totalDuration: const Duration(minutes: 2, seconds: 7),
    );
