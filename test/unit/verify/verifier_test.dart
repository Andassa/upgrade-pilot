import 'package:test/test.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';
import 'package:upgrade_pilot/src/verify/child_environment.dart';
import 'package:upgrade_pilot/src/verify/verifier.dart';

import '../../support/fakes.dart';

final class _Recorder implements ProgressObserver {
  final events = <String>[];

  @override
  void planContext({
    required String project,
    required String? from,
    required String target,
    required List<String> platforms,
  }) {}
  @override
  void stageStarted(String id, {Map<String, Object?> args = const {}}) {}
  @override
  void stageProgress(String id, String detail) {}
  @override
  void stageFinished(
    String id,
    StepStatus status, {
    String? labelKey,
    String? detailKey,
    Map<String, Object?> args = const {},
    Duration? duration,
  }) {}
  @override
  void attemptStarted(int number, int max, List<String> changes) {}
  @override
  void stepStarted(String step) => events.add('start $step');
  @override
  void stepFinished(Evidence evidence) =>
      events.add('end ${evidence.step} ${evidence.status.name}');
}

void main() {
  late FakeProcessRunner runner;
  late _Recorder observer;
  Verifier verifier({DateTime? now}) => Verifier(
        runner: runner,
        diagnoser: Diagnoser.embedded(),
        redactor: Redactor(homeDirectory: '/home/dev'),
        clock: () => now ?? DateTime.utc(2026),
      );
  Future<AttemptOutcome> run(
    List<String> steps, {
    int jobs = 1,
    DateTime? deadline,
    CancellationToken? cancellation,
  }) =>
      verifier().verify(
        projectDirectory: '/sandbox/src',
        flutter: '/sdk/bin/flutter',
        environment: const {'PATH': '/sdk/bin'},
        plan: VerifyPlan(steps: steps),
        attempt: 1,
        deadline: deadline ?? DateTime.utc(2100),
        observer: observer,
        cancellation: cancellation,
        jobs: jobs,
      );

  setUp(() {
    runner = FakeProcessRunner();
    observer = _Recorder();
  });

  test('runs steps in order with the target SDK and analytics off', () async {
    runner
      ..on('pub get', (_) => outcome())
      ..on(
        'analyze',
        (_) => outcome(
          stdout: '   info • Prefer const • lib/a.dart:1:1 • prefer_const',
        ),
      )
      ..on('build apk', (_) => outcome());
    final result = await run([Steps.pubGet, Steps.analyze, Steps.buildApk]);
    expect(result.succeeded, isTrue);
    expect(result.hasWarnings, isFalse);
    expect(result.evidence.map((e) => e.detail), [null, '1 info', null]);
    final command = runner.commands.first;
    expect(command.executable, '/sdk/bin/flutter');
    expect(command.workingDirectory, '/sandbox/src');
    expect(command.arguments, ['pub', 'get', '--suppress-analytics']);
    expect(command.timeout, isNotNull);
    expect(result.evidence.first.command, 'flutter pub get');
    expect(observer.events, [
      'start pub get',
      'end pub get ok',
      'start analyze',
      'end analyze ok',
      'start build apk',
      'end build apk ok',
    ]);
  });

  test('analyzer errors and warnings are warnings, not failures', () async {
    runner
      ..on('pub get', (_) => outcome())
      ..on(
        'analyze',
        (_) => outcome(
          exitCode: 1,
          stdout: '  error - lib/a.dart:1:1 - Undefined name - undefined\n'
              '  warning • Unused import • lib/b.dart:1:1 • unused_import\n'
              '  warning • Unused import • lib/c.dart:1:1 • unused_import\n'
              'password=hunter2',
        ),
      );
    final result = await run([Steps.pubGet, Steps.analyze]);
    final analyze = result.evidence.last;
    expect(analyze.status, StepStatus.warning);
    expect(analyze.detail, '1 error, 2 warnings');
    expect(result.succeeded, isTrue);
    expect(result.hasWarnings, isTrue);

    runner.on('analyze', (_) => outcome(exitCode: 3, stdout: 'crash'));
    final crashed = await run([Steps.pubGet, Steps.analyze]);
    expect(crashed.evidence.last.detail, 'analyzer exited with 3');
  });

  test('a failure is diagnosed and later steps are skipped', () async {
    runner
      ..on('pub get', (_) => outcome())
      ..on(
        'build apk',
        (_) => outcome(
          exitCode: 1,
          stderr: "The 'org.jetbrains.kotlin.android' plugin is no longer "
              'required for Kotlin support since AGP 9.0.',
        ),
      );
    final result = await run([Steps.pubGet, Steps.buildApk, Steps.test]);
    expect(result.succeeded, isFalse);
    expect(result.failedStep, Steps.buildApk);
    expect(result.diagnoses.first.finding.id, 'UP-AND-0007');
    final build = result.evidence[1];
    expect(build.status, StepStatus.failed);
    expect(build.detail, 'UP-AND-0007');
    expect(build.findingId, 'UP-AND-0007');
    expect(result.evidence.last.status, StepStatus.skipped);
    expect(result.evidence.last.detail, 'an earlier step failed');
  });

  test('pub get failure skips everything else', () async {
    runner.on('pub get', (_) => outcome(exitCode: 1, stderr: 'boom'));
    final result = await run([Steps.pubGet, Steps.analyze]);
    expect(result.failedStep, Steps.pubGet);
    expect(result.evidence.last.status, StepStatus.skipped);
    expect(result.evidence.first.detail, 'exit code 1');
  });

  test('timeouts and exhausted budgets', () async {
    runner.on(
      'pub get',
      (_) => const ProcessOutcome(
        exitCode: -15,
        stdout: '',
        stderr: '',
        duration: Duration(minutes: 1),
        timedOut: true,
      ),
    );
    final timedOut = await run([Steps.pubGet]);
    expect(timedOut.diagnoses.single.finding.id, Verifier.timeoutId);
    expect(timedOut.diagnoses.single.isEnvironment, isTrue);
    expect(timedOut.evidence.single.detail, 'timed out');

    final late = await run([Steps.pubGet], deadline: DateTime.utc(2000));
    expect(late.evidence.single.detail, 'time budget exhausted');
    expect(late.failedStep, Steps.pubGet);
  });

  test('cancellation', () async {
    final token = CancellationToken();
    runner.on('pub get', (_) {
      token.cancel();
      return const ProcessOutcome(
        exitCode: -2,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
        cancelled: true,
      );
    });
    final result =
        await run([Steps.pubGet, Steps.analyze], cancellation: token);
    expect(result.cancelled, isTrue);
    expect(result.succeeded, isFalse);
    expect(result.evidence.first.detail, 'interrupted');
  });

  test('parallel jobs run every step after pub get', () async {
    runner
      ..on('pub get', (_) => outcome())
      ..on('analyze', (_) => outcome())
      ..on('build apk', (_) => outcome())
      ..on('test', (_) => outcome(exitCode: 1, stderr: 'Some tests failed.'));
    final result = await run(
      [Steps.pubGet, Steps.analyze, Steps.buildApk, Steps.test],
      jobs: 3,
    );
    expect(result.evidence, hasLength(4));
    expect(result.failedStep, Steps.test);
    expect(await run(const []), isA<AttemptOutcome>());
  });

  test('Steps.arguments rejects unknown steps', () {
    expect(() => Steps.arguments('deploy'), throwsArgumentError);
  });

  group('childEnvironment', () {
    test('keeps only allow-listed variables and puts the SDK first', () {
      final env = childEnvironment(
        {
          'PATH': '/home/dev/flutter/bin:/usr/bin',
          'HOME': '/home/dev',
          'JAVA_HOME': '/jdk',
          'GITHUB_TOKEN': 'secret',
          'AWS_SECRET_ACCESS_KEY': 'secret',
        },
        '/cache/sdks/3.44.9/flutter',
        windows: false,
      );
      expect(env['PATH'], '/cache/sdks/3.44.9/flutter/bin:/usr/bin');
      expect(env['HOME'], '/home/dev');
      expect(env['JAVA_HOME'], '/jdk');
      expect(env, isNot(contains('GITHUB_TOKEN')));
      expect(env, isNot(contains('AWS_SECRET_ACCESS_KEY')));
      expect(env['FLUTTER_SUPPRESS_ANALYTICS'], 'true');
    });

    test('Windows uses Path and semicolons', () {
      final env = childEnvironment(
        {'Path': r'C:\flutter\bin;C:\Windows', 'SystemRoot': r'C:\Windows'},
        r'C:\sdk\flutter',
        windows: true,
      );
      expect(env['Path'], startsWith(r'C:\sdk\flutter'));
      expect(env['Path'], endsWith(r';C:\Windows'));
      expect(env['SystemRoot'], r'C:\Windows');
      expect(
        childEnvironment(const {}, '/sdk', windows: false)['PATH'],
        '/sdk/bin',
      );
    });
  });
}
