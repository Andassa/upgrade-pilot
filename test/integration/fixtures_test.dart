@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:upgrade_pilot/upgrade_pilot.dart';

import '../support/builders.dart';
import '../support/fakes.dart';

/// Real runs on `test/fixtures` with the Flutter SDK of the machine.
/// The target defaults to the installed Flutter version, so no SDK is
/// downloaded; set UPGRADE_PILOT_TARGET to test another one.
void main() {
  late String target;

  setUpAll(() async {
    final result = await Process.run(
      'flutter',
      ['--version', '--machine'],
      runInShell: Platform.isWindows,
    );
    final json = jsonDecode('${result.stdout}') as Map<String, Object?>;
    target = Platform.environment['UPGRADE_PILOT_TARGET'] ??
        json['frameworkVersion']! as String;
  });

  Future<(int, Map<String, Object?>)> plan(
    String fixtureName, {
    List<String> extra = const [],
  }) async {
    final host = LocalHost();
    final console = FakeConsole();
    final code = await runCli(
      [
        '--json',
        'plan',
        '--path',
        fixture(fixtureName),
        '--to',
        target,
        '--platforms',
        Platform.environment['INTEGRATION_PLATFORMS'] ?? 'android',
        '--timeout',
        '40m',
        ...extra,
      ],
      Services(
        fs: LocalFileSystem(),
        runner: LocalProcessRunner(environment: host.environment),
        http: AllowlistedHttp(),
        host: host,
        clock: DateTime.now,
        console: console,
      ),
    );
    stdout.writeln(console.errors);
    return (code, jsonDecode(console.output) as Map<String, Object?>);
  }

  test('healthy project: verified without changes to the toolchain', () async {
    final (code, json) = await plan('healthy');
    expect(
      json['verdict'],
      isNot('blocked'),
      reason: const JsonEncoder.withIndent(' ').convert(json),
    );
    expect(code, ExitCodes.ok);
    final evidence =
        (json['evidence']! as List<Object?>).cast<Map<String, Object?>>();
    expect(
      evidence.where((e) => e['step'] == 'build apk' && e['status'] == 'ok'),
      isNotEmpty,
    );
  });

  test('legacy toolchain: repaired automatically and proven by a build',
      () async {
    final (code, json) = await plan('legacy_toolchain');
    expect(
      json['verdict'],
      isNot('blocked'),
      reason: const JsonEncoder.withIndent(' ').convert(json['findings']),
    );
    expect(code, ExitCodes.ok);
    final changes =
        (json['changes']! as List<Object?>).cast<Map<String, Object?>>();
    expect(
      changes.map((c) => c['path']),
      containsAll([
        'pubspec.yaml',
        'android/gradle/wrapper/gradle-wrapper.properties',
      ]),
    );
    expect((json['attempts']! as List<Object?>).length, greaterThan(1));
  });

  test('blocked dependency: explained, exit code 2', () async {
    final (code, json) = await plan('blocked_dependency');
    expect(code, ExitCodes.blocked);
    final blocked =
        (json['blocked']! as List<Object?>).cast<Map<String, Object?>>();
    expect(blocked.single['subject'], startsWith('progress_dialog'));
    expect(blocked.single['suggestionVerified'], isFalse);
  });
}
