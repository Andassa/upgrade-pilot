import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/cli/cli.dart';
import 'package:upgrade_pilot/src/cli/errors.dart';
import 'package:upgrade_pilot/src/domain/exit_codes.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';

import '../../support/fakes.dart';
import '../../support/scenario.dart';

void main() {
  late Scenario scenario;
  late FakeConsole console;

  Map<String, Object?> json() =>
      jsonDecode(console.output) as Map<String, Object?>;

  Future<int> run(List<String> args, {FakeConsole? using}) {
    console = using ?? FakeConsole();
    return runCli(args, scenario.services(console: console));
  }

  setUp(() => scenario = Scenario());

  test('--version and --json --version', () async {
    expect(await run(['--version']), ExitCodes.ok);
    expect(console.output, 'upgrade-pilot 1.0.0\n');
    await run(['--json', '--version']);
    expect(jsonDecode(console.output), {'version': '1.0.0'});
  });

  test('no command: welcome on a TTY, usage otherwise', () async {
    await run([], using: FakeConsole(stdoutIsTty: true, columns: 100));
    expect(console.output, contains('Get started'));
    expect(console.output, contains('█'));
    await run([]);
    expect(console.output, contains('Usage: upgrade-pilot <command>'));
    expect(console.output, contains('Exit codes:'));
  });

  test('usage errors use the error format and exit 1', () async {
    expect(await run(['plan', '--jobs', '0']), ExitCodes.usage);
    expect(console.errors, contains('Invalid command line'));
    expect(console.errors, contains('--jobs must be a positive integer'));
    expect(await run(['plan', '--timeout', 'soon']), ExitCodes.usage);
    expect(await run(['nope']), ExitCodes.usage);
    expect(await run(['explain']), ExitCodes.usage);
    expect(await run(['completion', 'powershell']), ExitCodes.usage);
    expect(await run(['--json', 'nope']), ExitCodes.usage);
    expect((json()['error']! as Map<String, Object?>)['code'], ExitCodes.usage);
  });

  test('plan: verified exits 0 and prints the summary', () async {
    expect(await run(['--ci', 'plan', '--to', '3.44.9']), ExitCodes.ok);
    final out = console.output;
    expect(out, contains('upgrade-pilot 1.0.0'));
    expect(out, contains('Project'));
    expect(out, contains('Verified plan'));
    expect(out, contains('upgrade-pilot apply'));
    expect(out, matches(RegExp(r'\[\d\d:\d\d:\d\d\]')));
  });

  test('plan --json prints the versioned report only', () async {
    expect(await run(['--json', 'plan', '--to', '3.44.9']), ExitCodes.ok);
    final json = jsonDecode(console.output) as Map<String, Object?>;
    expect(json['reportSchemaVersion'], 1);
    expect(json['verdict'], 'verified');
  });

  test('plan: blocked exits 2; --quiet prints only the verdict', () async {
    scenario.buildLog = 'mystery';
    expect(await run(['--quiet', 'plan', '--to', '3.44.9']), ExitCodes.blocked);
    expect(console.output, isEmpty);
    expect(console.errors, contains('Plan blocked'));
  });

  test('plan: unknown target exits 1, offline without cache exits 3', () async {
    expect(await run(['plan', '--offline']), ExitCodes.environment);
    expect(console.errors, contains('Not available offline'));
    expect(await run(['plan', '--to', '9.9.9']), ExitCodes.usage);
    expect(console.errors, contains('Unknown Flutter version'));
  });

  test('plan: not a Flutter project exits 1', () async {
    scenario.fs.addFile('/work/cli/pubspec.yaml', 'name: cli\n');
    expect(await run(['plan', '--path', '/work/cli']), ExitCodes.usage);
    expect(console.errors, contains('Not a Flutter project'));
  });

  test('plan: Ctrl+C exits 4 and removes the sandbox', () async {
    final tty = FakeConsole();
    scenario.runner.on('pub get', (c) {
      tty.interrupt();
      return const ProcessOutcome(
        exitCode: -2,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
        cancelled: true,
      );
    });
    expect(
      await run(['plan', '--to', '3.44.9'], using: tty),
      ExitCodes.interrupted,
    );
    expect(console.errors, contains('Interrupted'));
    expect(
      scenario.fs.directories.where((d) => d.startsWith('/tmp/upgrade-pilot-')),
      isEmpty,
    );
  });

  group('after a plan', () {
    setUp(() async {
      await run(['plan', '--to', '3.44.9']);
    });

    test('report in every format', () async {
      expect(await run(['report', '--format', 'md']), ExitCodes.ok);
      expect(console.output, startsWith('## upgrade-pilot'));
      expect(await run(['report', '-f', 'json']), ExitCodes.ok);
      expect(json()['verdict'], 'verified');
      scenario.runner.on('xdg-open', (_) => outcome());
      expect(await run(['report', '--open']), ExitCodes.ok);
      expect(
        console.output,
        contains('Report written to ~/.cache/upgrade-pilot/plans/'),
      );
      expect(scenario.runner.commands.last.executable, 'xdg-open');
      expect(await run(['report', '-o', 'out.md', '-f', 'md']), ExitCodes.ok);
      expect(
        scenario.fs.text('$projectRoot/out.md'),
        startsWith('## upgrade-pilot'),
      );
      expect(await run(['--json', 'report']), ExitCodes.ok);
      expect(json()['format'], 'html');
    });

    test('explain a finding of the plan, and a rule', () async {
      expect(await run(['explain', 'UP-PUB-0002']), ExitCodes.ok);
      expect(console.output, contains('pub suggests a newer constraint'));
      expect(console.output, contains('flutter pub add http:^1.6.0'));
      expect(await run(['explain', 'UP-IOS-0002']), ExitCodes.ok);
      expect(console.output, contains('Not seen in the last plan'));
      expect(await run(['--json', 'explain', 'UP-AND-0007']), ExitCodes.ok);
      expect(
        (json()['rule']! as Map<String, Object?>)['source'],
        startsWith('https://'),
      );
      expect(await run(['explain', 'UP-ZZZ-0000']), ExitCodes.usage);
    });

    test('apply needs confirmation, then reverts', () async {
      expect(await run(['apply']), ExitCodes.usage);
      expect(console.errors, contains('Confirmation required'));
      final declined = FakeConsole(stdinIsTty: true, input: ['n']);
      expect(await run(['apply'], using: declined), ExitCodes.ok);
      expect(console.output, contains('Nothing was changed.'));
      final accepted = FakeConsole(stdinIsTty: true, input: ['y']);
      expect(await run(['apply'], using: accepted), ExitCodes.ok);
      expect(
        console.output,
        contains('Backup: ~/.cache/upgrade-pilot/backups/'),
      );
      expect(scenario.fs.text('$projectRoot/pubspec.yaml'), contains('^1.6.0'));
      expect(await run(['apply', '--revert']), ExitCodes.ok);
      expect(console.output, contains('Restored'));
      expect(
        scenario.fs.text('$projectRoot/pubspec.yaml'),
        contains('^0.12.2'),
      );
    });

    test('apply --yes --json', () async {
      expect(await run(['--json', 'apply', '--yes']), ExitCodes.ok);
      final json = jsonDecode(console.output) as Map<String, Object?>;
      expect(json['applied'], contains('pubspec.yaml'));
      expect(await run(['--json', 'apply', '--revert']), ExitCodes.ok);
    });

    test('apply refuses after the project changed (exit 2)', () async {
      scenario.fs.addFile('$projectRoot/pubspec.yaml', 'name: legacy_app\n');
      expect(await run(['apply', '--yes']), ExitCodes.blocked);
      expect(console.errors, contains('The project changed since the plan'));
    });
  });

  test('doctor', () async {
    scenario.runner
        .on('git --version', (_) => outcome(stdout: 'git version 2.50.1'));
    expect(await run(['doctor', '--offline']), ExitCodes.ok);
    expect(console.output, contains('Ready to plan.'));
    expect(await run(['--json', 'doctor', '--offline']), ExitCodes.ok);
    expect(json()['ok'], isTrue);
    scenario.runner.onPath.clear();
    expect(await run(['doctor', '--offline']), ExitCodes.environment);
    expect(console.output, contains('A required tool is missing.'));
  });

  test('kb update, clean and completion', () async {
    expect(await run(['kb', 'update']), ExitCodes.environment);
    expect(console.errors, contains('Network error'));
    expect(await run(['clean', '--keep-sdks']), ExitCodes.ok);
    expect(console.output, contains('Nothing to clean.'));
    expect(await run(['--json', 'clean']), ExitCodes.ok);
    for (final (shell, flag) in [
      ('bash', '--to'),
      ('zsh', '--to'),
      ('fish', '-l to'),
    ]) {
      expect(await run(['completion', shell]), ExitCodes.ok);
      expect(console.output, contains('upgrade-pilot'));
      expect(console.output, contains(flag), reason: shell);
    }
  });

  test('French output', () async {
    expect(await run(['--lang', 'fr', 'apply']), ExitCodes.usage);
    expect(console.errors, contains('Aucun plan pour ce projet'));
    expect(console.errors, contains('Que faire'));
  });

  test('ASCII and no-color output', () async {
    await run(
      ['--ascii', '--no-color', 'apply'],
      using: FakeConsole(stdoutIsTty: true, columns: 80),
    );
    expect(console.errors, contains('x No plan for this project'));
    expect(console.errors, isNot(contains('\x1B[')));
  });

  group('describeError', () {
    final s = Strings.of('en');
    final r = Redactor(homeDirectory: '/home/dev');

    test('maps environment problems to exit 3', () {
      expect(
        describeError(
          InsufficientDiskException(
            required: 4 << 30,
            available: 1 << 30,
          ),
          s,
          r,
        ).why,
        '4.0 GB are needed, 1.0 GB are free.',
      );
      expect(
        describeError(FsException('full', noSpace: true), s, r).code,
        ExitCodes.environment,
      );
      expect(
        describeError(SdkException('x'), s, r).code,
        ExitCodes.environment,
      );
      expect(
        describeError(ProcessStartException('flutter', 'missing'), s, r).code,
        ExitCodes.environment,
      );
      expect(
        describeError(
          NetworkException('down', uri: Uri.parse('https://pub.dev')),
          s,
          r,
        ).why,
        'down (https://pub.dev)',
      );
    });

    test('unexpected errors are internal (70)', () {
      final e = describeError(StateError('boom at /home/dev/x'), s, r);
      expect(e.code, ExitCodes.internal);
      expect(e.internal, isTrue);
      expect(e.why, contains('~/x'));
    });
  });

  test('--verbose shows a redacted stack trace for internal errors', () async {
    scenario.runner.on('pub get', (_) => throw StateError('unexpected'));
    expect(
      await run(['--verbose', 'plan', '--to', '3.44.9']),
      ExitCodes.internal,
    );
    expect(console.errors, contains('Unexpected error'));
    expect(console.errors, contains('.dart'));
  });
}
