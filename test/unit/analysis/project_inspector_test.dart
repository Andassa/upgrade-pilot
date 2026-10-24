import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/analysis/project_inspector.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/infra/local_file_system.dart';

import '../../support/builders.dart';
import '../../support/fakes.dart';

void main() {
  final inspector = ProjectInspector(LocalFileSystem());

  test('reads the legacy fixture (Groovy, Flutter 3.24 template)', () async {
    final s = await inspector.inspect(fixture('legacy_toolchain'));
    expect(s.name, 'legacy_app');
    expect(s.pubspec.dependency('http')!.constraint, '^0.12.2');
    expect(s.flutterPin!.source, FlutterPinSource.metadata);
    expect(s.flutterPin!.revision, startsWith('dec2ee5'));
    final android = s.android!;
    expect(android.gradle, Version(8, 3, 0));
    expect(android.gradleDistributionType, 'all');
    expect(android.agp, Version(8, 1, 0));
    expect(android.agpDeclaredIn, ProjectFiles.settingsGroovy);
    expect(android.kotlin, Version(1, 8, 22));
    expect(android.usesKotlinDsl, isFalse);
    expect(android.appliesKotlinPlugin, isTrue);
    expect(android.javaTarget, 8);
    expect(android.minSdk!.flutterManaged, isTrue);
    expect(android.gradleProperties['android.enableJetifier'], 'true');
    expect(s.hasIos, isFalse);
  });

  test('reads the healthy fixture (Kotlin DSL, Flutter 3.44 template)',
      () async {
    final s = await inspector.inspect(fixture('healthy'));
    expect(s.name, 'healthy_app');
    final android = s.android!;
    expect(android.agp, Version(9, 0, 1));
    expect(android.kotlin, Version(2, 3, 20));
    expect(android.gradle, Version(9, 1, 0));
    expect(android.usesKotlinDsl, isTrue);
    expect(android.appliesKotlinPlugin, isFalse);
    expect(android.gradleProperties['android.builtInKotlin'], 'false');
    expect(s.ios!.xcodeDeploymentTarget, isNotNull);
  });

  test('reads the blocked fixture', () async {
    final s = await inspector.inspect(fixture('blocked_dependency'));
    expect(s.pubspec.dependency('progress_dialog')!.constraint, '^1.2.4');
  });

  group('with an in-memory project', () {
    late MemoryFileSystem fs;
    setUp(() => fs = MemoryFileSystem());

    test('FVM pins win over .metadata', () async {
      fs.addTree('/p', {
        'pubspec.yaml':
            'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n',
        '.fvmrc': '{"flutter": "3.24.5"}',
        '.metadata': 'version:\n  revision: "x"\n  channel: "stable"\n',
        'ios/Podfile': "platform :ios, '12.0'\n",
        'ios/Podfile.lock': 'COCOAPODS: 1.15.0\n',
      });
      final s = await ProjectInspector(fs).inspect('/p');
      expect(s.flutterPin!.version, '3.24.5');
      expect(s.ios!.podfilePlatform, Version(12, 0, 0));
      expect(s.ios!.cocoapodsVersion, '1.15.0');
      expect(s.hasAndroid, isFalse);
    });

    test('legacy FVM config is used without .fvmrc', () async {
      fs.addTree('/p', {
        'pubspec.yaml':
            'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n',
        '.fvm/fvm_config.json': '{"flutterSdkVersion": "3.22.3"}',
      });
      final s = await ProjectInspector(fs).inspect('/p');
      expect(s.flutterPin!.version, '3.22.3');
    });

    test('rejects folders that are not Flutter apps', () async {
      final inspector = ProjectInspector(fs);
      await expectLater(
        inspector.inspect('/empty'),
        throwsA(isA<NotAFlutterProjectException>()),
      );
      fs.addFile('/dart/pubspec.yaml', 'name: cli\n');
      await expectLater(
        inspector.inspect('/dart'),
        throwsA(
          isA<NotAFlutterProjectException>().having(
            (e) => e.toString(),
            'message',
            contains('does not depend on the Flutter SDK'),
          ),
        ),
      );
    });

    test('android folder without Gradle files', () async {
      fs
        ..addFile(
          '/p/pubspec.yaml',
          'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n',
        )
        ..addFile('/p/android/README', 'x');
      final s = await ProjectInspector(fs).inspect('/p');
      expect(s.android!.agp, isNull);
      expect(s.android!.gradle, isNull);
    });
  });
}
