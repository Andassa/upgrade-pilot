import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/analysis/gradle_parser.dart';
import 'package:upgrade_pilot/src/analysis/ios_parser.dart';
import 'package:upgrade_pilot/src/analysis/metadata_parser.dart';
import 'package:upgrade_pilot/src/analysis/pubspec_parser.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';

void main() {
  group('parsePubspec', () {
    test('reads name, environment and dependencies of every kind', () {
      final info = parsePubspec('''
name: my_app
environment:
  sdk: ">=3.0.0 <4.0.0"
  flutter: ">=3.10.0"
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
  any_dep:
  any_word: any
  pinned: 2.0.0
  hosted_map:
    version: ^3.0.0
    hosted: https://pub.dev
  from_git:
    git: https://github.com/a/b.git
  local:
    path: ../local
dev_dependencies:
  test: ^1.25.0
resolution: workspace
''');
      expect(info.name, 'my_app');
      expect(info.dartConstraint, '>=3.0.0 <4.0.0');
      expect(info.flutterConstraint, '>=3.10.0');
      expect(info.dependsOnFlutter, isTrue);
      expect(info.resolutionWorkspace, isTrue);
      expect(info.hasWorkspace, isFalse);
      expect(info.dependency('http')!.constraint, '^1.2.0');
      expect(info.dependency('any_dep')!.constraint, isNull);
      expect(info.dependency('any_word')!.constraint, isNull);
      expect(info.dependency('hosted_map')!.constraint, '^3.0.0');
      expect(info.dependency('from_git')!.kind, DependencyKind.git);
      expect(info.dependency('local')!.kind, DependencyKind.path);
      expect(info.dependency('local')!.path, '../local');
      expect(info.dependency('test')!.isDev, isTrue);
      expect(info.dependency('missing'), isNull);
    });

    test('rejects invalid documents', () {
      expect(
        () => parsePubspec('name: [unclosed'),
        throwsA(isA<ManifestException>()),
      );
      expect(() => parsePubspec('- a list'), throwsA(isA<ManifestException>()));
      expect(
        () => parsePubspec('version: 1.0.0'),
        throwsA(isA<ManifestException>()),
      );
      expect(
        ManifestException('pubspec.yaml', 'boom').toString(),
        'pubspec.yaml: boom',
      );
    });

    test('a workspace root is detected', () {
      expect(
        parsePubspec('name: root\nworkspace:\n  - packages/app\n').hasWorkspace,
        isTrue,
      );
    });
  });

  test('parsePubspecLock', () {
    final lock = parsePubspecLock('''
packages:
  http:
    dependency: "direct main"
    description:
      name: http
    source: hosted
    version: "1.6.0"
  meta:
    dependency: transitive
    source: hosted
    version: "1.19.0"
sdks:
  dart: ">=3.5.0 <4.0.0"
''');
    expect(lock['http']!.version, '1.6.0');
    expect(lock['http']!.dependency, 'direct main');
    expect(lock['meta']!.source, 'hosted');
    expect(parsePubspecLock(''), isEmpty);
    expect(parsePubspecLock('sdks: {}'), isEmpty);
    expect(() => parsePubspecLock('a: [b'), throwsA(isA<ManifestException>()));
  });

  group('gradle', () {
    test('wrapper versions and distribution type', () {
      final all = parseGradleWrapper(
        r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.3-all.zip',
      )!;
      expect(all.version, Version(8, 3, 0));
      expect(all.type, 'all');
      final bin = parseGradleWrapper(
        'distributionUrl=https://example.com/gradle-9.1.0-rc-2-bin.zip',
      )!;
      expect(bin.version.toString(), '9.1.0-rc-2');
      expect(bin.type, 'bin');
      expect(parseGradleWrapper('nothing'), isNull);
    });

    test('AGP and Kotlin from plugins blocks (Groovy and Kotlin DSL)', () {
      const groovy = '''
plugins {
    id "com.android.application" version "8.1.0" apply false
    // id "com.android.application" version "1.0.0" apply false
    id "org.jetbrains.kotlin.android" version "1.8.22" apply false
}''';
      const kts = '''
plugins {
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}''';
      expect(findAgpVersion({'s.gradle': groovy})!.version, Version(8, 1, 0));
      expect(
        findKotlinVersion({'s.gradle': groovy})!.version,
        Version(1, 8, 22),
      );
      expect(findAgpVersion({'s.kts': kts})!.file, 's.kts');
      expect(findKotlinVersion({'s.kts': kts})!.version, Version(2, 3, 20));
    });

    test('legacy buildscript declarations', () {
      const legacy = r'''
buildscript {
    ext.kotlin_version = '1.7.10'
    dependencies {
        classpath 'com.android.tools.build:gradle:7.3.0'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"
    }
}''';
      expect(findAgpVersion({'b.gradle': legacy})!.version, Version(7, 3, 0));
      expect(
        findKotlinVersion({'b.gradle': legacy})!.version,
        Version(1, 7, 10),
      );
      expect(
        findKotlinVersion({
          'b.gradle':
              'classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.0"',
        })!
            .version,
        Version(1, 9, 0),
      );
    });

    test('version catalogs', () {
      const toml = '''
[versions]
agp = "8.7.3"
kotlin = "2.1.0"

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
''';
      expect(parseVersionCatalog(toml), {'agp': '8.7.3', 'kotlin': '2.1.0'});
      expect(
        findAgpVersion({'libs.versions.toml': toml})!.version,
        Version(8, 7, 3),
      );
      expect(
        findKotlinVersion({'libs.versions.toml': toml})!.version,
        Version(2, 1, 0),
      );
      expect(
        findAgpVersion({'libs.versions.toml': '[versions]\nx = "1"'}),
        isNull,
      );
    });

    test('properties', () {
      expect(
        parseProperties('# c\n! c\na=1\n b = two \nnoequals\n=empty\n'),
        {'a': '1', 'b': 'two'},
      );
    });

    test('app module: sdk levels, java target and kotlin plugin', () {
      final groovy = parseAppModule('''
plugins {
    id "com.android.application"
    id "kotlin-android"
}
android {
    compileSdk = flutter.compileSdkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
    }
    defaultConfig {
        minSdkVersion 21
        targetSdk = 34
    }
}''');
      expect(groovy.compileSdk!.flutterManaged, isTrue);
      expect(groovy.minSdk!.value, 21);
      expect(groovy.targetSdk!.value, 34);
      expect(groovy.javaTarget, 8);
      expect(groovy.appliesKotlinPlugin, isTrue);

      final kts = parseAppModule('''
plugins {
    id("com.android.application")
    // id("kotlin-android")
}
android {
    compileSdk = 36
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17 }
    defaultConfig { minSdk = flutter.minSdkVersion }
}''');
      expect(kts.compileSdk!.value, 36);
      expect(kts.minSdk!.flutterManaged, isTrue);
      expect(kts.javaTarget, 17);
      expect(kts.appliesKotlinPlugin, isFalse);
      expect(
        parseAppModule('apply plugin: "kotlin-android"').appliesKotlinPlugin,
        isTrue,
      );
    });

    test('stripGradleComments keeps strings and URLs', () {
      expect(
        stripGradleComments('a // c\nurl = "https://x" // y\n/* b\n c */d'),
        'a \nurl = "https://x" \n\nd',
      );
      expect(stripGradleComments(r"s = 'it\'s // not'"), r"s = 'it\'s // not'");
    });
  });

  test('ios parsers', () {
    expect(parsePodfilePlatform("platform :ios, '13.0'"), Version(13, 0, 0));
    expect(parsePodfilePlatform("# platform :ios, '12.0'"), isNull);
    expect(
      parseXcodeDeploymentTarget(
        'IPHONEOS_DEPLOYMENT_TARGET = 12.0;\nIPHONEOS_DEPLOYMENT_TARGET = '
        '"13.0";',
      ),
      Version(13, 0, 0),
    );
    expect(parseXcodeDeploymentTarget('nothing'), isNull);
    expect(
      parsePodfileLockCocoapods('PODFILE CHECKSUM: x\n\nCOCOAPODS: 1.16.2\n'),
      '1.16.2',
    );
  });

  test('flutter pins', () {
    expect(parseFvmrc('{"flutter": "3.24.5"}')!.version, '3.24.5');
    expect(parseFvmrc('{"flutterSdkVersion": "stable"}')!.version, 'stable');
    expect(parseFvmrc('{}'), isNull);
    expect(parseFvmrc('not json'), isNull);
    expect(
      parseFvmConfig('{"flutterSdkVersion": "3.22.3"}')!.source,
      FlutterPinSource.fvmConfig,
    );
    expect(parseFvmConfig('[]'), isNull);
    final metadata = parseMetadata('''
version:
  revision: "dec2ee5c1f"
  channel: "stable"
project_type: app
''')!;
    expect(metadata.revision, 'dec2ee5c1f');
    expect(metadata.version, 'stable');
    expect(parseMetadata('a: [b'), isNull);
    expect(parseMetadata('- x'), isNull);
    expect(parseMetadata('project_type: app'), isNull);
  });
}
