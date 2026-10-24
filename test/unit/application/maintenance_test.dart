import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/application/change_summary.dart';
import 'package:upgrade_pilot/src/application/git.dart';
import 'package:upgrade_pilot/src/application/maintenance_use_cases.dart';
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/application/toolchain_probe.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/kb/embedded_kb.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

import '../../support/builders.dart';
import '../../support/fakes.dart';
import '../../support/scenario.dart';

void main() {
  group('doctor', () {
    test('a complete Linux machine', () async {
      final scenario = Scenario();
      scenario.runner
          .on('git --version', (_) => outcome(stdout: 'git version 2.50.1'));
      scenario.http.json(
        'https://pub.dev/api/packages/pub_semver',
        {'name': 'pub_semver'},
      );
      final checks = await (await scenario.services().doctorUseCase()).run();
      final byName = {for (final c in checks) c.name: c};
      expect(byName['Flutter']!.status, StepStatus.ok);
      expect(byName['Flutter']!.detail, startsWith('3.44.9'));
      expect(byName['git']!.detail, '2.50.1');
      expect(byName['JDK']!.detail, contains('25.0.3'));
      expect(byName['Android SDK']!.status, StepStatus.ok);
      expect(byName['Xcode']!.status, StepStatus.skipped);
      expect(byName['Network']!.status, StepStatus.ok);
      expect(byName['Disk']!.status, StepStatus.ok);
      expect(byName['Knowledge base']!.detail, contains('2026.10.24'));
      expect(checks.any((c) => c.blocking), isFalse);
    });

    test('missing Flutter is blocking; other gaps are warnings', () async {
      final scenario = Scenario();
      scenario.runner.onPath.clear();
      scenario.fs
        ..files.remove('/opt/android-studio/jbr/bin/java')
        ..directories.removeWhere((d) => d.startsWith('/home/dev/Android'))
        ..files.removeWhere((k, _) => k.startsWith('/home/dev/Android'))
        ..free = 1024;
      scenario.http.offline = true;
      final checks = await (await scenario.services().doctorUseCase()).run();
      final byName = {for (final c in checks) c.name: c};
      expect(byName['Flutter']!.blocking, isTrue);
      expect(byName['git']!.status, StepStatus.warning);
      expect(byName['JDK']!.status, StepStatus.warning);
      expect(byName['Android SDK']!.status, StepStatus.warning);
      expect(byName['Network']!.status, StepStatus.warning);
      expect(byName['Disk']!.status, StepStatus.warning);
      final offline =
          await (await scenario.services().doctorUseCase()).run(offline: true);
      expect(
        offline.firstWhere((c) => c.name == 'Network').status,
        StepStatus.skipped,
      );
    });

    test('macOS checks Xcode and CocoaPods', () async {
      final fs = MemoryFileSystem()..free = null;
      final runner =
          FakeProcessRunner(onPath: {'xcodebuild': '/usr/bin/xcodebuild'})
            ..on(
              'xcodebuild',
              (_) => outcome(stdout: 'Xcode 27.0\nBuild version 27A266a'),
            );
      final probe =
          ToolchainProbe(fs: fs, runner: runner, host: FakeHost(os: 'macos'));
      expect(await probe.xcode(), 'Xcode 27.0');
      expect(await probe.cocoapods(), isNull);
      final linux = ToolchainProbe(fs: fs, runner: runner, host: FakeHost());
      expect(await linux.xcode(), isNull);
    });

    test('Android SDK from Flutter config or ANDROID_HOME', () async {
      final fs = MemoryFileSystem()
        ..addFile(
          '/home/dev/.config/flutter/settings',
          '{"android-sdk": "/sdk/custom"}',
        )
        ..addFile('/sdk/custom/platforms/x', '')
        ..addFile('/sdk/env/platforms/x', '');
      final runner = FakeProcessRunner();
      expect(
        await ToolchainProbe(fs: fs, runner: runner, host: FakeHost())
            .androidSdk(),
        '/sdk/custom',
      );
      fs.addFile('/home/dev/.config/flutter/settings', 'broken');
      expect(
        await ToolchainProbe(
          fs: fs,
          runner: runner,
          host: FakeHost(environment: {'ANDROID_HOME': '/sdk/env'}),
        ).androidSdk(),
        '/sdk/env',
      );
    });
  });

  group('explain', () {
    test('uses the finding of the last plan, else the rule', () async {
      final fs = MemoryFileSystem()..addFile('/p/pubspec.yaml', 'name: p');
      final store = PlanStore(fs, FakeHost());
      await store.save('/p', samplePlan());
      final services = Scenario().services();
      final explain = ExplainUseCase(store, services.rules);
      final fromPlan = await explain.explain('/p', 'up-pub-0002');
      expect(fromPlan.finding!.excerpt, contains('flutter pub add'));
      expect(fromPlan.rule!.id, 'UP-PUB-0002');
      final ruleOnly = await explain.explain('/p', 'UP-AND-0007');
      expect(ruleOnly.finding, isNull);
      expect(ruleOnly.rule, isNotNull);
      await expectLater(
        explain.explain('/p', 'UP-XXX-9999'),
        throwsA(isA<UnknownFindingException>()),
      );
      fs.addFile(await store.planPath('/p'), '{broken');
      expect((await explain.explain('/p', 'UP-AND-0007')).rule, isNotNull);
    });
  });

  group('plan store', () {
    test('round trip and unreadable plans', () async {
      final fs = MemoryFileSystem();
      final store = PlanStore(fs, FakeHost());
      expect(await store.load('/p'), isNull);
      await store.save('/p', samplePlan());
      final loaded = (await store.load('/p'))!;
      expect(jsonEncode(loaded.toJson()), jsonEncode(samplePlan().toJson()));
      expect(
        await store.directoryFor('/p'),
        startsWith('/home/dev/.cache/upgrade-pilot/plans/'),
      );
      fs.addFile(await store.planPath('/p'), '[]');
      await expectLater(store.load('/p'), throwsA(isA<PlanStoreException>()));
      fs.addFile(await store.planPath('/p'), '{"schemaVersion": 99}');
      await expectLater(store.load('/p'), throwsA(isA<PlanStoreException>()));
      expect(PlanStoreException('m').toString(), 'm');
    });

    test('fingerprint changes when a covered file changes', () async {
      final fs = MemoryFileSystem()..addFile('/p/pubspec.yaml', 'name: a');
      final a = await projectFingerprint(fs, '/p');
      fs.addFile('/p/lib/main.dart', 'not covered');
      expect(await projectFingerprint(fs, '/p'), a);
      fs.addFile('/p/android/build.gradle', 'covered');
      expect(await projectFingerprint(fs, '/p'), isNot(a));
    });
  });

  group('kb update', () {
    const base =
        'https://raw.githubusercontent.com/Andassa/upgrade-pilot/main/data/';
    late MemoryFileSystem fs;
    late FakeHttp http;
    late KbUpdateUseCase useCase;
    final services = Scenario().services();

    setUp(() {
      fs = MemoryFileSystem();
      http = FakeHttp();
      useCase = KbUpdateUseCase(http: http, fs: fs, loader: services.kbLoader);
    });

    String newer() {
      final json = jsonDecode(embeddedKb) as Map<String, Object?>;
      json['kbVersion'] = '2099.01.01';
      return jsonEncode(json);
    }

    test('installs a newer, verified KB', () async {
      final content = newer();
      http
        ..text('${base}kb.json', content)
        ..text('${base}kb.json.sha256', '${sha256Hex(content)}\n');
      final result = await useCase.update();
      expect(result.updated, isTrue);
      expect(result.current, '2099.01.01');
      expect(fs.text(services.kbLoader.cachedPath), content);
    });

    test('keeps the current KB when not newer', () async {
      http
        ..text('${base}kb.json', embeddedKb)
        ..text('${base}kb.json.sha256', sha256Hex(embeddedKb));
      expect((await useCase.update()).updated, isFalse);
    });

    test('rejects a checksum mismatch or a failed download', () async {
      http
        ..text('${base}kb.json', newer())
        ..text('${base}kb.json.sha256', 'f' * 64);
      await expectLater(
        useCase.update(),
        throwsA(isA<KnowledgeBaseException>()),
      );
      http.responses.remove('${base}kb.json');
      await expectLater(useCase.update(), throwsA(isA<NetworkException>()));
    });
  });

  test('clean removes caches and stale sandboxes but keeps backups', () async {
    final fs = MemoryFileSystem()
      ..addFile('/home/dev/.cache/upgrade-pilot/sdks/3.44.9/x', '')
      ..addFile('/home/dev/.cache/upgrade-pilot/plans/a/plan.json', '')
      ..addFile('/home/dev/.cache/upgrade-pilot/backups/a/m.json', '')
      ..addFile('/tmp/upgrade-pilot-1/src/x', '')
      ..addFile('/tmp/other/x', '');
    final clean = CleanUseCase(fs, FakeHost());
    final kept = await clean.clean(keepSdks: true);
    expect(
      kept,
      containsAll(
        ['/home/dev/.cache/upgrade-pilot/plans', '/tmp/upgrade-pilot-1'],
      ),
    );
    expect(fs.text('/home/dev/.cache/upgrade-pilot/sdks/3.44.9/x'), isNotNull);
    final removed = await clean.clean();
    expect(removed, ['/home/dev/.cache/upgrade-pilot/sdks']);
    expect(
      fs.text('/home/dev/.cache/upgrade-pilot/backups/a/m.json'),
      isNotNull,
    );
    expect(fs.text('/tmp/other/x'), isNotNull);
    expect(await clean.clean(), isEmpty);
  });

  group('change summaries', () {
    final redactor = Redactor(homeDirectory: '/home/dev');
    Change describe(String path, String? before, String after) =>
        describeChange(path, before, after, redactor: redactor);

    test('every kind of file', () {
      expect(
        describe(
          'android/gradle/wrapper/gradle-wrapper.properties',
          'distributionUrl=x/gradle-8.3-all.zip',
          'distributionUrl=x/gradle-9.1.0-all.zip',
        ).summary,
        'Gradle 8.3 → 9.1.0',
      );
      expect(
        describe(
          'android/app/build.gradle',
          'minSdk = 21\ncompileSdk = 34\nsourceCompatibility = '
              'JavaVersion.VERSION_1_8',
          'minSdk = 24\ncompileSdk = 36\nsourceCompatibility = '
              'JavaVersion.VERSION_17',
        ).summary,
        'minSdk 21 → 24, compileSdk 34 → 36, Java target 8 → 17',
      );
      expect(
        describe(
          'android/gradle.properties',
          'a=1\n',
          'a=1\nandroid.newDsl=false\n',
        ).summary,
        'android.newDsl=false',
      );
      expect(
        describe(
          'pubspec.yaml',
          'name: a\nenvironment:\n  sdk: ^2.19.0\ndependencies:\n  http: '
              '^0.12.2\n',
          'name: a\nenvironment:\n  sdk: ">=2.19.0 <4.0.0"\ndependencies:\n  '
              'http: ^1.6.0\n',
        ).summary,
        'sdk ^2.19.0 → >=2.19.0 <4.0.0, http ^0.12.2 → ^1.6.0',
      );
      expect(
        describe('pubspec.yaml', 'x: [', 'y: [').summary,
        contains('Flutter tool'),
      );
      expect(
        describe('pubspec.lock', null, 'packages: {}').summary,
        'created by pub get',
      );
      expect(
        describe(
          'pubspec.lock',
          'packages:\n  a:\n    version: "1.0.0"\n',
          'packages:\n  a:\n    version: "2.0.0"\n',
        ).summary,
        '1 package re-resolved',
      );
      expect(
        describe('ios/Podfile.lock', 'a', 'b').summary,
        'updated by pod install',
      );
      expect(
        describe(
          'ios/Podfile',
          "# platform :ios, '12.0'",
          "platform :ios, '13.0'",
        ).summary,
        'iOS none → 13.0.0',
      );
      expect(
        describe(
          'ios/Runner.xcodeproj/project.pbxproj',
          'IPHONEOS_DEPLOYMENT_TARGET = 12.0;',
          'IPHONEOS_DEPLOYMENT_TARGET = 13.0;',
        ).summary,
        'IPHONEOS_DEPLOYMENT_TARGET 12.0.0 → 13.0.0',
      );
      expect(
        describe('ios/Runner/AppDelegate.swift', 'a', 'b').summary,
        'migrated by the Flutter tool during the build',
      );
      expect(
        describe('.fvmrc', '{}', '{"flutter":"3.44.9"}').kind,
        ChangeKind.flutterPin,
      );
      expect(
        describe(
          'android/gradle/libs.versions.toml',
          '[versions]\nagp = "8.1.0"',
          '[versions]\nagp = "9.0.1"',
        ).summary,
        'AGP 8.1.0 → 9.0.1',
      );
    });

    test('diffs are redacted, hunks are minimal', () {
      final change = describe(
        'android/gradle.properties',
        'storePassword=hunter2\na=1\n',
        'storePassword=hunter2\na=2\n',
      );
      expect(change.diff, isNot(contains('hunter2')));
      expect(change.diff, contains('storePassword=<redacted>'));
      expect(change.hunks.single.insert, ['a=2']);
      expect(change.beforeSha256, sha256Hex('storePassword=hunter2\na=1\n'));
    });

    test('dependency moves ignore first resolutions', () {
      final moves = dependencyMoves(
        legacySnapshot(),
        newPubspec: 'name: legacy_app\ndependencies:\n  http: ^1.6.0\n  extra: '
            '^1.0.0\n',
        newLock: 'packages:\n  http:\n    version: "1.6.0"\n',
      );
      expect(moves.map((m) => m.name), ['http', 'extra']);
      expect(dependencyMoves(legacySnapshot()), isEmpty);
    });
  });

  test('git client', () async {
    final runner = FakeProcessRunner()
      ..on('--is-inside-work-tree', (_) => outcome(stdout: 'true\n'))
      ..on('status --porcelain', (_) => outcome())
      ..on('rev-parse HEAD', (_) => outcome(stdout: 'abc123\n'));
    final git =
        GitClient(runner, const {'PATH': '/usr/bin', 'HOME': '/home/dev'});
    expect(await git.isRepository('/p'), isTrue);
    expect(await git.isClean('/p'), isTrue);
    expect(await git.head('/p'), 'abc123');
    expect(runner.commands.first.environment['GIT_TERMINAL_PROMPT'], '0');
    final missing = GitClient(FakeProcessRunner(), const {});
    expect(await missing.isRepository('/p'), isFalse);
    expect(await missing.isClean('/p'), isFalse);
    expect(await missing.head('/p'), isNull);
    final failing = GitClient(
      FakeProcessRunner()..on('rev-parse HEAD', (_) => outcome(exitCode: 128)),
      const {},
    );
    expect(await failing.head('/p'), isNull);
  });

  test('ProcessStartException and CancelledException describe themselves', () {
    expect(
      ProcessStartException('flutter', 'nope').toString(),
      'Cannot start flutter: nope',
    );
    expect(const CancelledException().toString(), 'Interrupted');
  });
}
