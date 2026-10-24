import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/infra/local_file_system.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sandbox/copy_policy.dart';
import 'package:upgrade_pilot/src/sandbox/sandbox.dart';

import '../../support/fakes.dart';

void main() {
  group('CopyPolicy', () {
    test('secrets', () {
      for (final name in [
        'upload.jks',
        'release.keystore',
        'key.properties',
        '.env',
        '.env.production',
        'AuthKey.p8',
        'cert.pem',
        'firebase-service-account.json',
        'id_rsa',
        'dist.mobileprovision',
      ]) {
        expect(CopyPolicy.isSecret(name), isTrue, reason: name);
      }
      for (final name in [
        'pubspec.yaml',
        'google-services.json',
        'main.dart',
      ]) {
        expect(CopyPolicy.isSecret(name), isFalse, reason: name);
      }
    });

    test('machine files and tracked files', () {
      expect(CopyPolicy.isMachineFile('local.properties'), isTrue);
      expect(CopyPolicy.isMachineFile('app.iml'), isTrue);
      expect(CopyPolicy.isTracked('android/app/build.gradle.kts'), isTrue);
      expect(CopyPolicy.isTracked('ios/Podfile'), isTrue);
      expect(CopyPolicy.isTracked('lib/main.dart'), isFalse);
      expect(
        CopyPolicy.isTracked('ios/Runner/GeneratedPluginRegistrant.m'),
        isFalse,
      );
      expect(CopyPolicy.isGenerated('pubspec.lock'), isTrue);
      expect(CopyPolicy.isGenerated('pubspec.yaml'), isFalse);
    });
  });

  group('Sandbox (in memory)', () {
    late MemoryFileSystem fs;
    late SandboxFactory factory;

    setUp(() {
      fs = MemoryFileSystem()
        ..addTree('/work/app', {
          'pubspec.yaml': 'name: app\n',
          'lib/main.dart': 'void main() {}',
          'android/settings.gradle': 'old',
          'android/key.properties': 'storePassword=hunter2',
          'android/app/upload.jks': 'binary',
          'android/local.properties': 'flutter.sdk=/home/dev/flutter',
          '.env': 'TOKEN=abc',
          'build/app.apk': 'x',
          '.dart_tool/cache': 'x',
          '.git/HEAD': 'ref',
          'ios/Pods/Pod.swift': 'x',
        })
        ..links['/work/app/outside'] = '/etc/passwd';
      factory = SandboxFactory(fs, FakeHost());
    });

    test('copies the project without secrets, outputs or links', () async {
      final sandbox = await factory.create(projectDirectory: '/work/app');
      expect(sandbox.root, startsWith('/tmp/upgrade-pilot-'));
      expect(sandbox.report.secretsExcluded, 3);
      expect(sandbox.report.linksSkipped, ['outside']);
      final copied =
          fs.files.keys.where((k) => k.startsWith(sandbox.copyRoot)).toList();
      final names = copied
          .map((k) => p.posix.relative(k, from: sandbox.copyRoot))
          .toSet();
      expect(
        names,
        {'pubspec.yaml', 'lib/main.dart', 'android/settings.gradle'},
      );
      expect(sandbox.report.files, 3);
      expect(factory.active, contains(sandbox));
    });

    test('tracks changes, resets them and reports new files', () async {
      final sandbox = await factory.create(projectDirectory: '/work/app');
      expect(sandbox.original('android/settings.gradle'), 'old');
      await sandbox.write('android/settings.gradle', 'new');
      await sandbox.write('pubspec.lock', 'packages: {}');
      await sandbox.write('lib/main.dart', 'changed but not tracked');
      final changes = await sandbox.changes();
      expect(
        changes.map((c) => c.path),
        ['android/settings.gradle', 'pubspec.lock'],
      );
      expect(changes.first.before, 'old');
      expect(changes.last.before, isNull);
      await sandbox.reset();
      expect(await sandbox.read('android/settings.gradle'), 'old');
      expect(await sandbox.read('pubspec.lock'), isNull);
      expect(await sandbox.changes(), isEmpty);
    });

    test('dispose removes everything, once', () async {
      final sandbox = await factory.create(projectDirectory: '/work/app');
      await sandbox.dispose();
      await sandbox.dispose();
      expect(fs.directories.any((d) => d.startsWith(sandbox.root)), isFalse);
      expect(factory.active, isEmpty);
      final other = await factory.create(projectDirectory: '/work/app');
      await factory.disposeAll();
      expect(fs.directories.any((d) => d.startsWith(other.root)), isFalse);
    });

    test('monorepo: copies the workspace root, works in the member', () async {
      fs.addTree('/work/mono', {
        'pubspec.yaml': 'name: root\nworkspace:\n  - apps/app\n',
        'packages/shared/pubspec.yaml': 'name: shared\n',
        'apps/app/pubspec.yaml': 'name: app\nresolution: workspace\n',
        'apps/app/android/build.gradle': 'x',
      });
      final sandbox = await factory.create(
        projectDirectory: '/work/mono/apps/app',
        copyRoot: '/work/mono',
      );
      expect(sandbox.projectPrefix, 'apps/app');
      expect(sandbox.projectDirectory, endsWith('/src/apps/app'));
      expect(
        fs.text(
          p.posix.join(sandbox.copyRoot, 'packages/shared/pubspec.yaml'),
        ),
        isNotNull,
      );
      await sandbox.write('android/build.gradle', 'y');
      await fs.writeString(
        p.posix.join(sandbox.copyRoot, 'pubspec.yaml'),
        'name: root2\n',
      );
      final changes = await sandbox.changes();
      expect(
        changes.single.path,
        'android/build.gradle',
        reason: 'outside the member is ignored',
      );
    });

    test('refuses a project outside the copy root', () async {
      await expectLater(
        factory.create(projectDirectory: '/work/app', copyRoot: '/work/other'),
        throwsA(isA<SandboxException>()),
      );
    });

    test('cleans up when the copy fails (disk full)', () async {
      final failing = _FailingCopyFs(fs);
      final f = SandboxFactory(failing, FakeHost());
      await expectLater(
        f.create(projectDirectory: '/work/app'),
        throwsA(isA<Object>()),
      );
      expect(
        fs.directories.where((d) => d.startsWith('/tmp/upgrade-pilot-')),
        isEmpty,
      );
    });
  });

  group('Sandbox on the real file system', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('up-sandbox-test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('private 0700 directory, never follows outbound links', () async {
      final project = Directory(p.join(temp.path, 'my app é'))..createSync();
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('name: a\n');
      File(p.join(project.path, 'key.properties')).writeAsStringSync('secret');
      final outside = File(p.join(temp.path, 'outside.txt'))
        ..writeAsStringSync('x');
      if (!Platform.isWindows) {
        Link(p.join(project.path, 'link.txt')).createSync(outside.path);
      }
      final host = FakeHost(temporaryDirectory: temp.path);
      final sandbox = await SandboxFactory(LocalFileSystem(), host)
          .create(projectDirectory: project.path);
      expect(
        File(p.join(sandbox.copyRoot, 'pubspec.yaml')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(sandbox.copyRoot, 'key.properties')).existsSync(),
        isFalse,
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(sandbox.copyRoot, 'link.txt'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      if (!Platform.isWindows) {
        final mode = Directory(sandbox.root).statSync().mode & 0x1ff;
        expect(mode.toRadixString(8), '700');
      }
      await sandbox.dispose();
      expect(Directory(sandbox.root).existsSync(), isFalse);
    });
  });
}

final class _FailingCopyFs extends MemoryFileSystem {
  _FailingCopyFs(this.base);

  final MemoryFileSystem base;

  @override
  Future<String> canonicalize(String path) => base.canonicalize(path);

  @override
  Future<List<int>?> readBytes(String path) => base.readBytes(path);

  @override
  Future<String> createPrivateTempDirectory(String parent, String prefix) =>
      base.createPrivateTempDirectory(parent, prefix);

  @override
  Future<void> deleteRecursive(String path) => base.deleteRecursive(path);

  @override
  Future<void> createDirectory(String path) => base.createDirectory(path);

  @override
  Future<List<FsEntry>> list(String directory) => base.list(directory);

  @override
  Future<void> copyFiles(String s, String t, List<String> f) async =>
      throw FsException('No space left on device', noSpace: true);
}
