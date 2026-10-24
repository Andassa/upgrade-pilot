import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/infra/allowlisted_http.dart';
import 'package:upgrade_pilot/src/infra/local_file_system.dart';
import 'package:upgrade_pilot/src/infra/local_host.dart';
import 'package:upgrade_pilot/src/infra/local_process_runner.dart';
import 'package:upgrade_pilot/src/infra/stdio_console.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('up-infra'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('LocalFileSystem', () {
    final fs = LocalFileSystem();

    test('atomic writes, reads, listing and deletion', () async {
      final file = p.join(temp.path, 'a', 'b', 'c.txt');
      await fs.writeString(file, 'héllo');
      expect(await fs.readString(file), 'héllo');
      expect(await fs.readBytes(file), utf8.encode('héllo'));
      expect(await fs.exists(file), isTrue);
      expect(await fs.isDirectory(p.join(temp.path, 'a')), isTrue);
      expect(await fs.readString(p.join(temp.path, 'missing')), isNull);
      expect(await fs.readBytes(p.join(temp.path, 'missing')), isNull);
      expect(
        Directory(p.join(temp.path, 'a', 'b')).listSync(),
        hasLength(1),
        reason: 'no temp file left',
      );
      if (!Platform.isWindows) {
        Link(p.join(temp.path, 'link')).createSync(file);
      }
      final entries = await fs.list(temp.path);
      expect(entries.first.type, EntryType.directory);
      if (!Platform.isWindows) {
        expect(entries.last.type, EntryType.link);
        expect(entries.last.linkTarget, file);
        await fs.deleteRecursive(p.join(temp.path, 'link'));
        expect(File(file).existsSync(), isTrue, reason: 'link target kept');
      }
      expect(await fs.list(p.join(temp.path, 'nope')), isEmpty);
      await fs.deleteRecursive(file);
      await fs.deleteRecursive(p.join(temp.path, 'nope'));
      await fs.deleteRecursive(p.join(temp.path, 'a'));
      expect(Directory(p.join(temp.path, 'a')).existsSync(), isFalse);
    });

    test('copies with clones and falls back, renames, hashes', () async {
      final src = p.join(temp.path, 'src');
      await fs.writeString(p.join(src, 'x', 'one.txt'), '1');
      await fs.writeString(p.join(src, 'x', 'two.txt'), '2');
      await fs.writeString(p.join(src, 'root.txt'), 'r');
      final dst = p.join(temp.path, 'dst');
      await fs.copyFiles(src, dst, ['x/one.txt', 'x/two.txt', 'root.txt']);
      expect(File(p.join(dst, 'x', 'two.txt')).readAsStringSync(), '2');
      await fs.rename(dst, p.join(temp.path, 'moved'));
      expect(Directory(p.join(temp.path, 'moved')).existsSync(), isTrue);
      await fs.rename(
        p.join(temp.path, 'moved', 'root.txt'),
        p.join(temp.path, 'r.txt'),
      );
      expect(await fs.sha256File(p.join(temp.path, 'r.txt')), hasLength(64));
      expect(await fs.sha256File(p.join(temp.path, 'none')), isNull);
      await expectLater(
        fs.copyFiles(src, p.join(temp.path, 'd2'), ['missing.txt']),
        throwsA(isA<FsException>()),
      );
    });

    test('private temp directories, free space, canonical paths', () async {
      final dir =
          await fs.createPrivateTempDirectory(p.join(temp.path, 'p'), 'x-');
      expect(p.basename(dir), startsWith('x-'));
      if (!Platform.isWindows) {
        expect(
          (Directory(dir).statSync().mode & 0x1ff).toRadixString(8),
          '700',
        );
        expect(
          await fs.freeBytes(p.join(temp.path, 'not', 'yet')),
          greaterThan(0),
        );
      }
      await fs.createDirectory(p.join(temp.path, 'n', 'm'));
      expect(
        await fs.canonicalize(p.join(temp.path, 'n', '..', 'n', 'm')),
        endsWith('m'),
      );
      expect(fs.separator, Platform.pathSeparator);
    });

    test('errors become FsException', () async {
      await expectLater(
        fs.canonicalize(p.join(temp.path, 'nope', 'x')),
        throwsA(
          isA<FsException>().having((e) => e.noSpace, 'noSpace', isFalse),
        ),
      );
      expect(FsException('m', path: '/x').toString(), 'm (/x)');
      expect(FsException('m').toString(), 'm');
    });
  });

  group('LocalProcessRunner', () {
    final runner = LocalProcessRunner();
    final env = {'PATH': Platform.environment['PATH'] ?? ''};
    final dart = Platform.resolvedExecutable;

    test('runs without inheriting the environment, streams lines', () async {
      final lines = <String>[];
      final result = await runner.run(
        Command(dart, const ['--version'], environment: env),
        onLine: lines.add,
      );
      expect(result.succeeded, isTrue);
      expect(result.output, contains('Dart SDK version'));
      expect(lines, isNotEmpty);
    });

    test(
      'reports exit codes, timeouts and cancellation',
      () async {
        final script = File(p.join(temp.path, 'slow.dart'))
          ..writeAsStringSync(
            'import "dart:io"; void main(a) async { if (a.isNotEmpty) '
            'exit(3); await Future.delayed(Duration(seconds: 30)); }',
          );
        final failed = await runner
            .run(Command(dart, [script.path, 'x'], environment: env));
        expect(failed.exitCode, 3);
        expect(failed.succeeded, isFalse);

        final timedOut = await runner.run(
          Command(
            dart,
            [script.path],
            environment: env,
            timeout: const Duration(seconds: 2),
          ),
        );
        expect(timedOut.timedOut, isTrue);
        expect(timedOut.succeeded, isFalse);

        final token = CancellationToken();
        Timer(const Duration(seconds: 2), token.cancel);
        final cancelled = await runner.run(
          Command(dart, [script.path], environment: env),
          cancellation: token,
        );
        expect(cancelled.cancelled, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('missing executables and which()', () async {
      await expectLater(
        runner.run(const Command('definitely-not-a-command-xyz', [])),
        throwsA(isA<ProcessStartException>()),
      );
      expect(await runner.which(dart), dart);
      expect(await runner.which('/no/such/file'), isNull);
      expect(
        await LocalProcessRunner(environment: {'PATH': p.dirname(dart)})
            .which(p.basenameWithoutExtension(dart)),
        isNotNull,
      );
      expect(
        await LocalProcessRunner(environment: {'PATH': '::'})
            .which('nothing-here'),
        isNull,
      );
    });
  });

  group('AllowlistedHttp', () {
    test('allow-list', () {
      for (final ok in [
        'https://pub.dev/api/packages/http',
        'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json',
        'https://raw.githubusercontent.com/Andassa/upgrade-pilot/main/data/kb.json',
      ]) {
        expect(AllowlistedHttp.isAllowed(Uri.parse(ok)), isTrue, reason: ok);
      }
      for (final bad in [
        'http://pub.dev/api/packages/http',
        'https://evil.com/api/packages/x',
        'https://pub.dev/packages/http',
        'https://user:pw@pub.dev/api/packages/x',
        'https://pub.dev:8443/api/packages/x',
        'https://raw.githubusercontent.com/other/repo/main/kb.json',
        'https://pub.dev/api/packages/../admin',
      ]) {
        expect(AllowlistedHttp.isAllowed(Uri.parse(bad)), isFalse, reason: bad);
      }
    });

    test('get, refusals and network errors', () async {
      final client = AllowlistedHttp(
        client: MockClient((request) async {
          expect(request.headers['user-agent'], 'upgrade-pilot');
          if (request.url.path.endsWith('/boom')) {
            throw http.ClientException('connection reset');
          }
          if (request.url.path.endsWith('/socket')) {
            throw const SocketException('unreachable');
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      final reply =
          await client.get(Uri.parse('https://pub.dev/api/packages/x'));
      expect(reply.ok, isTrue);
      expect(utf8.decode(reply.body), '{"ok":true}');
      await expectLater(
        client.get(Uri.parse('https://evil.com/')),
        throwsA(isA<NetworkException>()),
      );
      await expectLater(
        client.get(Uri.parse('https://pub.dev/api/packages/boom')),
        throwsA(isA<NetworkException>()),
      );
      await expectLater(
        client.get(Uri.parse('https://pub.dev/api/packages/socket')),
        throwsA(isA<NetworkException>()),
      );
      expect(
        NetworkException('m', uri: Uri.parse('https://x')).toString(),
        'm (https://x)',
      );
    });

    test('download streams to disk with progress', () async {
      final client = AllowlistedHttp(
        client: MockClient.streaming((request, body) async {
          if (request.url.path.endsWith('missing')) {
            return http.StreamedResponse(const Stream.empty(), 404);
          }
          return http.StreamedResponse(
            Stream.fromIterable([utf8.encode('ab'), utf8.encode('cd')]),
            200,
            contentLength: 4,
          );
        }),
      );
      final target = p.join(temp.path, 'dl', 'file.bin');
      final progress = <int>[];
      final size = await client.download(
        Uri.parse('https://storage.googleapis.com/flutter_infra_release/x.zip'),
        target,
        onProgress: (received, total) => progress.add(received),
      );
      expect(size, 4);
      expect(File(target).readAsStringSync(), 'abcd');
      expect(progress, [2, 4]);
      await expectLater(
        client.download(
          Uri.parse(
            'https://storage.googleapis.com/flutter_infra_release/missing',
          ),
          target,
        ),
        throwsA(isA<NetworkException>()),
      );
      final token = CancellationToken()..cancel();
      await expectLater(
        client.download(
          Uri.parse(
            'https://storage.googleapis.com/flutter_infra_release/x.zip',
          ),
          target,
          cancellation: token,
        ),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        client.download(Uri.parse('https://example.com/x'), target),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  test('LocalHost', () {
    final host = LocalHost(
      environment: {'HOME': '/home/u', 'UPGRADE_PILOT_CACHE': '/c'},
    );
    expect(host.cacheDirectory, '/c');
    expect(host.homeDirectory, '/home/u');
    expect(['macos', 'linux', 'windows'], contains(host.os));
    expect(['arm64', 'x64'], contains(host.architecture));
    expect(host.processors, greaterThan(0));
    expect(host.temporaryDirectory, isNotEmpty);
    expect(host.currentDirectory, isNotEmpty);
    if (!Platform.isWindows) {
      expect(
        LocalHost(environment: {'HOME': '/home/u'}).cacheDirectory,
        '/home/u/.cache/upgrade-pilot',
      );
      expect(
        LocalHost(environment: {'HOME': '/h', 'XDG_CACHE_HOME': '/x'})
            .cacheDirectory,
        '/x/upgrade-pilot',
      );
    }
    expect(LocalHost().environment, isNotEmpty);
  });

  test('StdioConsole', () async {
    final console = StdioConsole();
    expect(console.stdoutIsTty, isA<bool>());
    expect(console.stdinIsTty, isA<bool>());
    expect(console.columns == null || console.columns! > 0, isTrue);
    final subscription = console.interrupts.listen((_) {});
    await subscription.cancel();
  });
}
