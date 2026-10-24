import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/cli/cli.dart';
import 'package:upgrade_pilot/src/domain/exit_codes.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';

import '../support/fakes.dart';
import '../support/scenario.dart';

/// Fake secrets planted in the project and the environment by [Scenario].
final List<String> secrets = [
  'hunter2',
  fakeSecret(['sk', '-livefakefakefakefakefakefake']),
  fakeSecret(['ghp', '_abcdefghijklmnopqrstuvwxyz0123456789']),
];

void main() {
  test('no secret reaches output, reports, caches, backups or child processes',
      () async {
    final scenario = Scenario();
    final sandboxSnapshots = <String>[];
    scenario.runner.on('analyze', (c) {
      final dir = c.workingDirectory!;
      sandboxSnapshots.addAll(
        scenario.fs.files.keys
            .where((k) => k.startsWith(dir))
            .map((k) => k.substring(dir.length)),
      );
      return outcome(
        stdout: 'warning • password=hunter2 in a log line • lib/a.dart:1:1 • x',
      );
    });
    final console = FakeConsole();
    final services = scenario.services(console: console);

    expect(
      await runCli(['--ci', '--verbose', 'plan', '--to', '3.44.9'], services),
      ExitCodes.ok,
    );
    for (final format in ['md', 'json', 'html']) {
      expect(
        await runCli(['report', '--format', format], services),
        ExitCodes.ok,
      );
    }
    expect(await runCli(['explain', 'UP-PUB-0002'], services), ExitCodes.ok);
    expect(await runCli(['apply', '--yes'], services), ExitCodes.ok);

    final everything = StringBuffer()
      ..write(console.output)
      ..write(console.errors);
    for (final MapEntry(:key, :value) in scenario.fs.files.entries) {
      if (key.startsWith('/home/dev/.cache/')) {
        everything.write(utf8.decode(value, allowMalformed: true));
      }
    }
    for (final command in scenario.runner.commands) {
      everything.write(jsonEncode(command.environment));
    }
    final text = everything.toString();
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)), reason: 'leaked: $secret');
    }

    expect(sandboxSnapshots, isNot(contains('/android/key.properties')));
    expect(sandboxSnapshots, isNot(contains('/.env')));
    expect(
      sandboxSnapshots,
      contains('/android/gradle.properties'),
      reason: 'needed by the build',
    );
    expect(
      scenario.fs.directories.where((d) => d.startsWith('/tmp/upgrade-pilot-')),
      isEmpty,
    );
  });

  group('Redactor', () {
    final redactor =
        Redactor(homeDirectory: '/Users/alice', extraPaths: ['/srv/build']);

    test('masks common secret shapes', () {
      final samples = {
        'storePassword=abc123': 'storePassword=<redacted>',
        'MYAPP_UPLOAD_KEY_PASSWORD = s3cr3t':
            'MYAPP_UPLOAD_KEY_PASSWORD = <redacted>',
        fakeSecret(['api_key: "AIz', 'aSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI"']):
            'api_key: "<redacted>"',
        'Authorization: Bearer abcdefghijklmnop': 'Authorization: <redacted>',
        'curl -H "Bearer abcdefghijklmnop"': 'curl -H "Bearer <redacted>"',
        'https://user:pass@example.com/repo.git':
            'https://<redacted>@example.com/repo.git',
        fakeSecret(['token ghp', '_abcdefghijklmnopqrstuvwxyz0123456789']):
            'token <redacted>',
        fakeSecret(['key AKI', 'AABCDEFGHIJKLMNOP']): 'key <redacted>',
        fakeSecret(['slack xoxb', '-1234567890-abcdef']): 'slack <redacted>',
        fakeSecret([
          'jwt ey',
          'JhbGciOiJIUzI1NiJ9.ey',
          'JzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijkl',
        ]): 'jwt <redacted>',
        fakeSecret(['pat github_pat', '_11ABCDEFGHIJKLMNOPQRSTUV']):
            'pat <redacted>',
        fakeSecret(['openai sk', '-abcdefghijklmnopqrstuvwxyz']):
            'openai <redacted>',
        fakeSecret(['Google AIz', 'aSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI']):
            'Google <redacted>',
      };
      for (final MapEntry(:key, :value) in samples.entries) {
        expect(redactor.redact(key), value, reason: key);
      }
    });

    test('private keys and personal paths', () {
      expect(
        redactor.redact(
          fakeSecret([
            '-----BEGIN RSA PRIVATE',
            ' KEY-----\nMIIE\n-----END RSA PRIVATE',
            ' KEY-----',
          ]),
        ),
        '<redacted private key>',
      );
      expect(
        redactor.redact('/Users/alice/app/build.gradle'),
        '~/app/build.gradle',
      );
      expect(redactor.redact('/srv/build/x'), '~/x');
      expect(Redactor().redact('nothing secret here'), 'nothing secret here');
    });
  });
}
