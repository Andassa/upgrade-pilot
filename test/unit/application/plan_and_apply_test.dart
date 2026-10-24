import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/application/apply_use_case.dart';
import 'package:upgrade_pilot/src/application/plan_use_case.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';

import '../../support/fakes.dart';
import '../../support/scenario.dart';

void main() {
  late Scenario scenario;
  setUp(() => scenario = Scenario());

  Future<PlanResult> plan({
    String target = '3.44.9',
    bool keep = false,
    CancellationToken? cancellation,
    Set<String>? platforms,
    bool runTests = false,
  }) async {
    final useCase = await scenario.services().planUseCase(
          offline: false,
          observer: const SilentObserver(),
        );
    return useCase.execute(
      PlanRequest(
        projectPath: projectRoot,
        target: target,
        keepSandbox: keep,
        platforms: platforms,
        runTests: runTests,
      ),
      cancellation: cancellation,
    );
  }

  test('repairs pub and Android toolchain, then verifies the build', () async {
    final result = await plan();
    final p = result.plan;
    expect(p.verdict, Verdict.verified);
    // Minimal toolchain fails at pub get (fixed), then fails to build with
    // an unknown cause; the search backtracks to the target template.
    expect(
      p.attempts.map((a) => a.findingId),
      ['UP-PUB-0002', 'UP-GEN-0000', null],
    );
    expect(p.attempts.last.succeeded, isTrue);
    expect(
      p.attempts.last.description,
      contains('android.builtInKotlin=false'),
    );
    expect(p.target.version.toString(), '3.44.9');
    expect(p.project.flutterVersion, '3.44.9', reason: 'the global SDK');
    expect(p.sdkSource, 'global');
    final paths = p.changes.map((c) => c.path).toList();
    expect(
      paths,
      containsAll(
        ['pubspec.yaml', 'pubspec.lock', 'android/settings.gradle'],
      ),
    );
    final settings =
        p.changes.firstWhere((c) => c.path == 'android/settings.gradle');
    expect(settings.summary, contains('AGP 8.1.0 → '));
    expect(p.dependencyUpdates.single.name, 'http');
    expect(p.dependencyUpdates.single.toConstraint, '^1.6.0');
    expect(p.notVerified.map((n) => n.what), contains('Runtime behaviour'));
    expect(p.notVerified.map((n) => n.what), contains('Tests'));
    expect(p.manualSteps.first.title, contains('3.44.9'));
    expect(
      scenario.fs.directories.where((d) => d.startsWith('/tmp/upgrade-pilot-')),
      isEmpty,
      reason: 'sandbox removed',
    );
    expect(
      scenario.fs.text('$projectRoot/pubspec.yaml'),
      contains('^0.12.2'),
      reason: 'the project itself is never modified by plan',
    );
  });

  test('every flutter command gets an allow-listed environment', () async {
    await plan();
    final flutterCalls =
        scenario.runner.commands.where((c) => c.executable.endsWith('flutter'));
    expect(flutterCalls, isNotEmpty);
    for (final c in flutterCalls) {
      expect(c.environment, isNot(contains('GITHUB_TOKEN')));
      expect(c.workingDirectory, startsWith('/tmp/upgrade-pilot-'));
      expect(c.arguments, contains('--suppress-analytics'));
    }
  });

  test('blocked when no candidate builds, with the diagnosis kept', () async {
    scenario.buildLog = '* What went wrong:\nmystery failure\n';
    final p = (await plan()).plan;
    expect(p.verdict, Verdict.blocked);
    expect(p.blocked.single.subject, contains('Build failure'));
    expect(
      p.notVerified.map((n) => n.reason),
      contains('no automatic fix left to try'),
    );
    expect(p.isApplicable, isFalse);
  });

  test('environment problems stop the search', () async {
    scenario.buildLog = 'java.io.IOException: No space left on device';
    final p = (await plan()).plan;
    expect(p.verdict, Verdict.blocked);
    expect(p.findings.map((f) => f.id), contains('UP-ENV-0001'));
    expect(
      p.notVerified.map((n) => n.reason),
      contains('the machine must be fixed first (see diagnosis)'),
    );
  });

  test('keeps the sandbox on request and honours platforms and tests',
      () async {
    scenario.runner.on('flutter test', (_) => outcome());
    final result = await plan(keep: true, platforms: {'ios'}, runTests: true);
    expect(result.sandboxPath, startsWith('/tmp/upgrade-pilot-'));
    expect(
      result.plan.notVerified.map((n) => n.what),
      contains('Android build'),
    );
    expect(
      result.plan.notVerified.map((n) => '${n.what}: ${n.reason}'),
      contains('iOS build: the project has no ios/ folder'),
    );
    expect(result.plan.evidence.map((e) => e.step), contains('test'));
  });

  test('cancellation removes the sandbox and throws', () async {
    final token = CancellationToken()..cancel();
    await expectLater(
      plan(cancellation: token),
      throwsA(isA<CancelledException>()),
    );
    expect(
      scenario.fs.directories.where((d) => d.startsWith('/tmp/upgrade-pilot-')),
      isEmpty,
    );
  });

  group('apply', () {
    late ApplyUseCase apply;
    setUp(() => apply = scenario.services().applyUseCase());

    test('applies the verified plan and reverts it', () async {
      final before = Map.of(scenario.fs.files);
      await plan();
      final result = await apply.apply(projectRoot);
      expect(result.applied, isNotEmpty);
      expect(
        scenario.fs.text('$projectRoot/pubspec.yaml'),
        contains('http: ^1.6.0'),
      );
      expect(scenario.fs.text('$projectRoot/pubspec.lock'), contains('1.6.0'));
      expect(
        scenario.fs.text('$projectRoot/android/gradle.properties'),
        contains('MYAPP_STORE_PASSWORD=hunter2'),
        reason: 'untouched lines are kept',
      );
      final manifest =
          scenario.fs.text('${result.backupDirectory}/manifest.json')!;
      expect(
        manifest,
        isNot(contains('hunter2')),
        reason: 'backups only keep changed lines',
      );

      final reverted = await apply.revert(projectRoot);
      expect(reverted.restored, isNotEmpty);
      for (final path in legacyFiles.keys) {
        expect(
          scenario.fs.text('$projectRoot/$path'),
          utf8.decode(before['$projectRoot/$path']!),
          reason: path,
        );
      }
      expect(
        scenario.fs.text('$projectRoot/pubspec.lock'),
        isNull,
        reason: 'created file removed',
      );
      await expectLater(
        apply.revert(projectRoot),
        throwsA(_refusal(ApplyRefusal.noBackup)),
      );
    });

    test('refuses without plan, with a blocked plan, or after edits', () async {
      await expectLater(
        apply.apply(projectRoot),
        throwsA(_refusal(ApplyRefusal.noPlan)),
      );
      await plan();
      scenario.fs
          .addFile('$projectRoot/android/settings.gradle', 'edited after plan');
      await expectLater(
        apply.apply(projectRoot),
        throwsA(_refusal(ApplyRefusal.projectChanged)),
      );
      scenario.buildLog = 'mystery';
      await plan();
      await expectLater(
        apply.apply(projectRoot),
        throwsA(_refusal(ApplyRefusal.blockedPlan)),
      );
    });

    test('refuses a dirty git working tree unless forced', () async {
      await plan();
      scenario.runner
        ..on('rev-parse --is-inside-work-tree', (_) => outcome(stdout: 'true'))
        ..on('status --porcelain', (_) => outcome(stdout: ' M lib/main.dart'));
      await expectLater(
        apply.check(projectRoot),
        throwsA(_refusal(ApplyRefusal.dirtyWorktree)),
      );
      final (planned, contents) = await apply.check(projectRoot, force: true);
      expect(contents.keys, containsAll(planned.changes.map((c) => c.path)));
    });

    test('detects a file that no longer matches its checksum', () async {
      await plan();
      final store = scenario.services().store;
      final stored = (await store.load(projectRoot))!;
      final tampered = Plan.fromJson({
        ...stored.toJson(),
        'changes': [
          for (final c in stored.changes)
            {
              ...c.toJson(),
              if (c.path == 'pubspec.yaml') 'beforeSha256': 'f' * 64,
            },
        ],
      });
      await store.save(projectRoot, tampered);
      await expectLater(
        apply.check(projectRoot),
        throwsA(_refusal(ApplyRefusal.fileConflict)),
      );
    });

    test('revert refuses files edited after apply unless forced', () async {
      await plan();
      await apply.apply(projectRoot);
      final applied = scenario.fs.text('$projectRoot/pubspec.yaml')!;
      scenario.fs.addFile(
        '$projectRoot/pubspec.yaml',
        applied.replaceFirst('name: legacy_app', 'name: renamed_app'),
      );
      await expectLater(
        apply.revert(projectRoot),
        throwsA(_refusal(ApplyRefusal.fileConflict)),
      );
      final forced = await apply.revert(projectRoot, force: true);
      expect(forced.restored, contains('pubspec.yaml'));
      final reverted = scenario.fs.text('$projectRoot/pubspec.yaml')!;
      expect(
        reverted,
        contains('name: renamed_app'),
        reason: 'later edit kept',
      );
      expect(reverted, contains('http: ^0.12.2'), reason: 'plan change undone');
    });

    test('forced revert still refuses a file whose structure changed',
        () async {
      await plan();
      await apply.apply(projectRoot);
      scenario.fs.addFile('$projectRoot/pubspec.yaml', 'name: x\n');
      await expectLater(
        apply.revert(projectRoot, force: true),
        throwsA(_refusal(ApplyRefusal.fileConflict)),
      );
    });

    test('an empty plan cannot be applied', () async {
      await plan();
      final store = scenario.services().store;
      final stored = (await store.load(projectRoot))!;
      await store.save(
        projectRoot,
        Plan.fromJson({...stored.toJson(), 'changes': const <Object?>[]}),
      );
      await expectLater(
        apply.check(projectRoot),
        throwsA(_refusal(ApplyRefusal.emptyPlan)),
      );
      expect(
        ApplyRefusedException(ApplyRefusal.noPlan, detail: 'x').toString(),
        'noPlan: x',
      );
    });
  });

  test('changes are stored as hunks, never as full contents', () async {
    final p = (await plan()).plan;
    final json = jsonEncode(p.toJson());
    expect(json, isNot(contains('hunter2')));
    expect(json, isNot(contains('sk-livefake')));
    for (final c in p.changes) {
      expect(c.afterSha256, hasLength(64));
    }
  });
}

Matcher _refusal(ApplyRefusal reason) =>
    isA<ApplyRefusedException>().having((e) => e.reason, 'reason', reason);
