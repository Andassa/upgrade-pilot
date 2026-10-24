import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sdk/jdk_locator.dart';
import 'package:upgrade_pilot/src/sdk/release_catalog.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';

import '../../support/fakes.dart';

const releasesUrl =
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json';

Map<String, Object?> releasesJson() => {
      'base_url':
          'https://storage.googleapis.com/flutter_infra_release/releases',
      'current_release': {'stable': 'h3449', 'beta': 'hbeta'},
      'releases': [
        {
          'hash': 'hbeta',
          'channel': 'beta',
          'version': '3.48.0-0.1.pre',
          'dart_sdk_version': '3.14.0 (build 3.14.0-1.0.dev)',
          'release_date': '2026-10-20T10:00:00Z',
          'archive': 'beta/linux/flutter_linux_3.48.0-0.1.pre-beta.tar.xz',
          'sha256': 'b' * 64,
        },
        {
          'hash': 'h3449',
          'channel': 'stable',
          'version': '3.44.9',
          'dart_sdk_version': '3.12.2',
          'dart_sdk_arch': 'arm64',
          'release_date': '2026-08-06T10:00:00Z',
          'archive': 'stable/linux/flutter_linux_arm64_3.44.9-stable.tar.xz',
          'sha256': 'a' * 64,
        },
        {
          'hash': 'h3449',
          'channel': 'stable',
          'version': '3.44.9',
          'dart_sdk_version': '3.12.2',
          'dart_sdk_arch': 'x64',
          'release_date': '2026-08-06T10:00:00Z',
          'archive': 'stable/linux/flutter_linux_3.44.9-stable.tar.xz',
          'sha256': 'c' * 64,
        },
        {
          'hash': 'h3448',
          'channel': 'stable',
          'version': '3.44.8',
          'dart_sdk_version': '3.12.2',
          'release_date': '2026-07-23T10:00:00Z',
          'archive': 'stable/linux/flutter_linux_3.44.8-stable.tar.xz',
        },
        {
          'hash': 'x',
          'channel': 'stable',
          'version': 'v1.0.0',
          'release_date': 'bad',
        },
      ],
    };

void main() {
  group('ReleaseIndex', () {
    final index = ReleaseIndex.parse(
      jsonEncode(releasesJson()),
      architecture: 'x64',
      fromCache: false,
    );

    test('keeps the archive of the host architecture', () {
      final r = index.resolve('3.44.9');
      expect(r.archive, 'stable/linux/flutter_linux_3.44.9-stable.tar.xz');
      expect(r.sha256, 'c' * 64);
      expect(r.dartVersion, Version(3, 12, 2));
      expect(
        index.archiveUri(r).toString(),
        endsWith('flutter_linux_3.44.9-stable.tar.xz'),
      );
    });

    test('resolves channels, minors and exact versions', () {
      expect(index.resolve('stable').version, Version(3, 44, 9));
      expect(index.resolve('BETA').channel, 'beta');
      expect(index.resolve('latest').channel, 'beta');
      expect(index.resolve('3.44').version, Version(3, 44, 9));
      expect(index.resolve('3.48.0-0.1.pre').channel, 'beta');
      expect(index.byVersion(Version(3, 44, 8)), isNotNull);
      expect(index.byVersion(Version(1, 0, 0)), isNull);
    });

    test('rejects unknown targets', () {
      for (final spec in ['3.99.0', '2.0', 'nightly', 'dev']) {
        expect(
          () => index.resolve(spec),
          throwsA(isA<ReleaseCatalogException>()),
          reason: spec,
        );
      }
      expect(ReleaseCatalogException('x').toString(), 'x');
    });
  });

  group('ReleaseCatalog', () {
    late FakeHttp http;
    late MemoryFileSystem fs;
    var now = DateTime.utc(2026, 10, 24, 10);
    ReleaseCatalog catalog() =>
        ReleaseCatalog(http: http, fs: fs, host: FakeHost(), clock: () => now);

    setUp(() {
      http = FakeHttp();
      fs = MemoryFileSystem();
      now = DateTime.utc(2026, 10, 24, 10);
    });

    test('downloads, caches, then serves the fresh cache', () async {
      http.json(releasesUrl, releasesJson());
      final first = await catalog().load();
      expect(first.fromCache, isFalse);
      final second = await catalog().load();
      expect(second.fromCache, isTrue);
      expect(second.fallback, isFalse);
      expect(http.requested, hasLength(1));
    });

    test('falls back to a stale cache when offline or unreachable', () async {
      http.json(releasesUrl, releasesJson());
      await catalog().load();
      now = now.add(const Duration(days: 2));
      expect((await catalog().load(offline: true)).fallback, isTrue);
      http.offline = true;
      expect((await catalog().load()).fallback, isTrue);
    });

    test('fails clearly without cache', () async {
      await expectLater(
        catalog().load(offline: true),
        throwsA(
          isA<ReleaseCatalogException>()
              .having((e) => e.offline, 'offline', isTrue),
        ),
      );
      http.offline = true;
      await expectLater(catalog().load(), throwsA(isA<NetworkException>()));
      http
        ..offline = false
        ..text(releasesUrl, 'nope');
      await expectLater(
        catalog().load(),
        throwsA(isA<ReleaseCatalogException>()),
      );
      http.text(releasesUrl, 'err', status: 500);
      await expectLater(catalog().load(), throwsA(isA<NetworkException>()));
    });
  });

  group('SdkManager', () {
    late MemoryFileSystem fs;
    late FakeProcessRunner runner;
    late _DownloadingHttp http;
    final host = FakeHost();
    SdkManager manager() =>
        SdkManager(fs: fs, runner: runner, http: http, host: host);
    final index = ReleaseIndex.parse(
      jsonEncode(releasesJson()),
      architecture: 'x64',
      fromCache: false,
    );

    setUp(() {
      fs = MemoryFileSystem();
      runner =
          FakeProcessRunner(onPath: {'flutter': '/opt/flutter/bin/flutter'});
      http = _DownloadingHttp(fs);
      fs
        ..addFile('/opt/flutter/bin/flutter', '#!/bin/sh')
        ..addFile(
          '/opt/flutter/bin/cache/flutter.version.json',
          '{"frameworkVersion": "3.44.8"}',
        );
    });

    test('reuses the global SDK read-only when it matches', () async {
      final sdk = await manager().obtain(index.resolve('3.44.8'), index);
      expect(sdk.source, SdkSource.global);
      expect(sdk.flutter, p.join('/opt/flutter', 'bin', 'flutter'));
      expect(http.downloads, isEmpty);
    });

    test('reads the legacy version file', () async {
      fs
        ..files.remove('/opt/flutter/bin/cache/flutter.version.json')
        ..addFile('/opt/flutter/version', '3.24.5\n');
      expect((await manager().globalSdk())!.version, Version(3, 24, 5));
      fs.addFile('/opt/flutter/bin/cache/flutter.version.json', 'not json');
      expect((await manager().globalSdk())!.version, Version(3, 24, 5));
    });

    test('finds FVM and cached SDKs', () async {
      fs
        ..addFile('/home/dev/fvm/versions/3.44.9/bin/flutter', '')
        ..addFile('/home/dev/fvm/versions/3.44.9/version', '3.44.9');
      expect(
        (await manager().findInstalled(Version(3, 44, 9)))!.source,
        SdkSource.fvm,
      );
      fs.addFile(
        '/home/dev/.cache/upgrade-pilot/sdks/3.47.8/.upgrade-pilot-complete',
        'x',
      );
      final cached = await manager().findInstalled(Version(3, 47, 8));
      expect(cached!.source, SdkSource.cache);
      expect(await manager().cachedSdks(), hasLength(1));
    });

    test('downloads, verifies the checksum and extracts', () async {
      runner.on('tar', (c) {
        fs.addFile('${c.arguments.last}/flutter/bin/flutter', '');
        return outcome();
      });
      http.content = 'archive';
      final signed = indexSigned('archive');
      final sdk = await manager().obtain(signed.resolve('3.44.9'), signed);
      expect(sdk.source, SdkSource.download);
      expect(
        fs.text(
          '/home/dev/.cache/upgrade-pilot/sdks/3.44.9/.upgrade-pilot-complete',
        ),
        isNotNull,
      );
      expect(runner.commands.single.arguments.first, '-xJf');
      expect(fs.files.keys.where((k) => k.contains('/downloads/')), isEmpty);
    });

    test('refuses a corrupted download', () async {
      http.content = 'tampered';
      await expectLater(
        manager().obtain(index.resolve('3.44.9'), index),
        throwsA(
          isA<SdkException>()
              .having((e) => e.message, 'message', contains('Checksum')),
        ),
      );
    });

    test('fails on extraction errors, offline and without disk space',
        () async {
      final signed = indexSigned('x');
      final release = signed.resolve('3.44.9');
      http.content = 'x';
      runner.on('tar', (_) => outcome(exitCode: 2, stderr: 'broken'));
      await expectLater(
        manager().obtain(release, signed),
        throwsA(
          isA<SdkException>()
              .having((e) => e.environment, 'environment', isTrue),
        ),
      );
      expect(fs.directories.where((d) => d.contains('.staging-')), isEmpty);
      await expectLater(
        manager().obtain(release, index, offline: true),
        throwsA(isA<SdkException>()),
      );
      fs.free = 1024;
      await expectLater(
        manager().obtain(release, index),
        throwsA(isA<InsufficientDiskException>()),
      );
    });
  });

  group('JdkLocator', () {
    test('parses java -version output', () {
      expect(parseJavaMajor('openjdk version "25.0.3" 2025-10-21'), 25);
      expect(parseJavaMajor('java version "1.8.0_292"'), 8);
      expect(parseJavaMajor('openjdk version "17" 2021-09-14'), 17);
      expect(parseJavaMajor('nothing'), isNull);
    });

    test('follows Flutter order: config, Android Studio, JAVA_HOME, PATH',
        () async {
      final fs = MemoryFileSystem()
        ..addFile(
          '/home/dev/.config/flutter/settings',
          '{"jdk-dir": "/jdks/21"}',
        )
        ..addFile('/jdks/21/bin/java', '')
        ..addFile('/opt/android-studio/jbr/bin/java', '');
      final runner = FakeProcessRunner(onPath: {'java': '/usr/bin/java'})
        ..on(
          '/jdks/21/bin/java',
          (_) => outcome(stderr: 'openjdk version "21.0.4"'),
        )
        ..on(
          '/opt/android-studio/jbr/bin/java',
          (_) => outcome(stderr: 'openjdk version "17.0.9"'),
        )
        ..on(
          '/usr/bin/java',
          (_) => outcome(stderr: 'openjdk version "11.0.1"'),
        );
      final locator = JdkLocator(fs: fs, runner: runner, host: FakeHost());
      final jdk = (await locator.locate())!;
      expect(jdk.major, 21);
      expect(jdk.origin, 'flutter config');

      fs.files.remove('/home/dev/.config/flutter/settings');
      expect((await locator.locate())!.origin, 'Android Studio');

      fs.files.remove('/opt/android-studio/jbr/bin/java');
      final onPath = (await locator.locate())!;
      expect(onPath.origin, 'PATH');
      expect(onPath.version, '11.0.1');
    });

    test('returns null without any JDK', () async {
      final locator = JdkLocator(
        fs: MemoryFileSystem()
          ..addFile('/home/dev/.flutter_settings', 'bad json'),
        runner: FakeProcessRunner(),
        host: FakeHost(environment: {'JAVA_HOME': '/nope', 'PATH': ''}),
      );
      expect(await locator.locate(), isNull);
    });
  });
}

/// A release list whose 3.44.9 x64 archive has the checksum of [content].
ReleaseIndex indexSigned(String content) {
  final json = releasesJson();
  final releases = json['releases']! as List<Object?>;
  final x64 = releases[2]! as Map<String, Object?>;
  x64['sha256'] = sha256Hex(content);
  return ReleaseIndex.parse(
    jsonEncode(json),
    architecture: 'x64',
    fromCache: false,
  );
}

final class _DownloadingHttp extends FakeHttp {
  _DownloadingHttp(this.fs);

  final MemoryFileSystem fs;
  String content = '';
  final downloads = <Uri>[];

  @override
  Future<int> download(
    Uri uri,
    String destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    downloads.add(uri);
    await fs.writeString(destination, content);
    onProgress?.call(content.length, content.length);
    return content.length;
  }
}
