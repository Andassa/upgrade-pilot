import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/patch/diff.dart';
import 'package:upgrade_pilot/src/patch/gradle_patcher.dart';
import 'package:upgrade_pilot/src/patch/ios_patcher.dart';
import 'package:upgrade_pilot/src/patch/materializer.dart';
import 'package:upgrade_pilot/src/patch/pubspec_patcher.dart';

import '../../support/builders.dart';

void main() {
  group('gradle patcher', () {
    test('wrapper keeps flavour and uses published names', () {
      const content =
          r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.3-all.zip';
      expect(
        setGradleWrapperVersion(content, Version(8, 14, 0)).content,
        endsWith('gradle-8.14-all.zip'),
      );
      expect(
        setGradleWrapperVersion(content, Version(9, 1, 0)).content,
        endsWith('gradle-9.1.0-all.zip'),
      );
      expect(setGradleWrapperVersion('x', Version(9, 1, 0)).found, isFalse);
    });

    test('AGP in plugins block, classpath and catalog', () {
      const groovy = 'id "com.android.application" version "8.1.0" apply false';
      final edit = setAgpVersion(groovy, Version(9, 0, 1));
      expect(
        edit.content,
        'id "com.android.application" version "9.0.1" apply false',
      );
      expect(edit.changed && edit.found, isTrue);
      expect(
        setAgpVersion(
          "classpath 'com.android.tools.build:gradle:7.3.0'",
          Version(8, 7, 3),
        ).content,
        "classpath 'com.android.tools.build:gradle:8.7.3'",
      );
      expect(
        setAgpVersion('[versions]\nagp = "8.1.0"\n', Version(8, 9, 1)).content,
        '[versions]\nagp = "8.9.1"\n',
      );
      final same = setAgpVersion(groovy, Version(8, 1, 0));
      expect(same.found && !same.changed, isTrue);
      expect(setAgpVersion('nothing', Version(9, 0, 1)).found, isFalse);
    });

    test('Kotlin in its usual places', () {
      expect(
        setKotlinVersion(
          'id("org.jetbrains.kotlin.android") version "1.8.22" apply false',
          Version(2, 3, 20),
        ).content,
        'id("org.jetbrains.kotlin.android") version "2.3.20" apply false',
      );
      expect(
        setKotlinVersion("ext.kotlin_version = '1.7.10'", Version(2, 1, 0))
            .content,
        "ext.kotlin_version = '2.1.0'",
      );
      expect(
        setKotlinVersion(
          'classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.0"',
          Version(2, 1, 0),
        ).content,
        'classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0"',
      );
      expect(setKotlinVersion('x', Version(2, 1, 0)).found, isFalse);
    });

    test('properties are replaced or appended', () {
      expect(setProperty('a=1\nb=2\n', 'b', '3').content, 'a=1\nb=3\n');
      expect(setProperty('a=1', 'c', 'x').content, 'a=1\nc=x\n');
      expect(setProperty('', 'c', 'x').content, 'c=x\n');
      expect(setProperty('c = x\n', 'c', 'x').changed, isFalse);
    });

    test('sdk levels and JVM target', () {
      const groovy = '''
android {
    compileSdk = flutter.compileSdkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8
    }
    defaultConfig {
        minSdk = flutter.minSdkVersion
    }
}''';
      final min = setMinSdk(groovy, 24).content;
      expect(min, contains('minSdk = 24'));
      expect(setCompileSdk(groovy, 36).content, contains('compileSdk = 36'));
      final jvm = setJvmTarget(groovy, 17).content;
      expect(jvm, contains('sourceCompatibility = JavaVersion.VERSION_17'));
      expect(jvm, contains('jvmTarget = JavaVersion.VERSION_17'));
      expect(
        setJvmTarget("jvmTarget = '1.8'", 17).content,
        "jvmTarget = '17'",
      );
      expect(
        setJvmTarget('jvmTarget = JavaVersion.VERSION_11.toString()', 17)
            .content,
        'jvmTarget = JavaVersion.VERSION_17.toString()',
      );
      expect(
        setJvmTarget('jvmTarget = JvmTarget.JVM_11', 17).content,
        'jvmTarget = JvmTarget.JVM_17',
      );
      expect(setJvmTarget('nothing', 17).found, isFalse);
      expect(setMinSdk('minSdkVersion 21', 23).content, 'minSdkVersion 23');
      expect(setMinSdk('none', 23).found, isFalse);
    });
  });

  group('pubspec patcher', () {
    const pubspec = '''
name: app # keep me
environment:
  sdk: ">=2.17.0 <3.0.0"
dependencies:
  http: ^0.12.2
  mapped:
    version: ^1.0.0
  from_git:
    git: https://x
dev_dependencies:
  lints: ^2.0.0
''';

    test('updates constraints and keeps comments', () {
      final http = setDependencyConstraint(pubspec, 'http', '^1.6.0');
      expect(http.content, contains('http: ^1.6.0'));
      expect(http.content, contains('# keep me'));
      expect(
        setDependencyConstraint(pubspec, 'mapped', '^2.0.0').content,
        contains('version: ^2.0.0'),
      );
      expect(
        setDependencyConstraint(pubspec, 'lints', '^5.0.0').content,
        contains('lints: ^5.0.0'),
      );
      expect(
        setDependencyConstraint(pubspec, 'from_git', '^1.0.0').found,
        isFalse,
      );
      expect(
        setDependencyConstraint(pubspec, 'absent', '^1.0.0').found,
        isFalse,
      );
      expect(
        setDependencyConstraint(pubspec, 'http', '^0.12.2').changed,
        isFalse,
      );
      expect(setDependencyConstraint('- a', 'x', '1').found, isFalse);
    });

    test('widens the SDK constraint', () {
      final widened = widenSdkConstraint(pubspec, Version(3, 12, 2));
      expect(widened.content, contains('sdk: ">=2.17.0 <4.0.0"'));
      expect(
        widenSdkConstraint(widened.content, Version(3, 12, 2)).changed,
        isFalse,
      );
      expect(
        widenSdkConstraint(
          'name: a\nenvironment:\n  sdk: ">=3.20.0 <4.0.0"\n',
          Version(3, 12, 2),
        ).content,
        contains('sdk: ^3.12.0'),
      );
      expect(widenSdkConstraint('name: a', Version(3, 0, 0)).found, isFalse);
      expect(
        widenSdkConstraint(
          'name: a\nenvironment:\n  sdk: "nope"\n',
          Version(3, 0, 0),
        ).found,
        isFalse,
      );
    });
  });

  group('ios patcher', () {
    test('uncomments and sets the Podfile platform', () {
      expect(
        setPodfilePlatform("# platform :ios, '12.0'\n", Version(13, 0, 0))
            .content,
        "platform :ios, '13.0'\n",
      );
      expect(
        setPodfilePlatform('target "Runner"', Version(13, 0, 0)).found,
        isFalse,
      );
    });

    test('raises only lower deployment targets', () {
      const pbx =
          'IPHONEOS_DEPLOYMENT_TARGET = 12.0;\nIPHONEOS_DEPLOYMENT_TARGET = '
          '14.0;';
      expect(
        raiseXcodeDeploymentTarget(pbx, Version(13, 0, 0)).content,
        'IPHONEOS_DEPLOYMENT_TARGET = 13.0;\nIPHONEOS_DEPLOYMENT_TARGET = '
        '14.0;',
      );
      expect(raiseXcodeDeploymentTarget('x', Version(13, 0, 0)).found, isFalse);
    });
  });

  group('diff', () {
    test('unified diff with hunk headers', () {
      final diff = unifiedDiff(
        'a.txt',
        '1\n2\n3\n4\n5\n6\n7\n8\n9\n',
        '1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n',
      );
      expect(diff, startsWith('--- a/a.txt\n+++ b/a.txt\n@@ -2,7 +2,7 @@\n'));
      expect(diff, contains('-5\n+FIVE\n'));
      expect(unifiedDiff('a', 'same\n', 'same\n'), isEmpty);
    });

    test('new files and separate hunks', () {
      expect(
        unifiedDiff('n', null, 'x\n'),
        startsWith('--- /dev/null\n+++ b/n\n@@ -0,0 +1,1 @@\n+x'),
      );
      final lines = List.generate(30, (i) => '$i');
      final after = [...lines]
        ..[2] = 'two'
        ..[25] = 'twenty-five';
      final diff = unifiedDiff('f', lines.join('\n'), after.join('\n'));
      expect('@@'.allMatches(diff).length, 4, reason: 'two hunks');
    });

    test('hunks reproduce the after content', () {
      const before = 'a\nb\nc\nd\ne\n';
      const after = 'a\nB\nc\ne\nf\n';
      expect(applyHunks(before, computeHunks(before, after)), after);
      expect(applyHunks(null, computeHunks(null, after)), after);
      expect(diffStat(before, after), (added: 2, removed: 2));
    });
  });

  group('materializer', () {
    late Map<String, String> files;
    Future<String?> read(String path) async => files[path];
    Future<void> write(String path, String content) async =>
        files[path] = content;

    setUp(() {
      files = {
        'android/settings.gradle':
            'id "com.android.application" version "8.1.0" apply false\n'
                'id "org.jetbrains.kotlin.android" version "1.8.22" apply '
                'false\n',
        'android/gradle/wrapper/gradle-wrapper.properties':
            'distributionUrl=https://services.gradle.org/distributions/gradle-8.3-all.zip\n',
        'android/app/build.gradle':
            'minSdk = flutter.minSdkVersion\ncompileSdk = 34\n'
                'sourceCompatibility = JavaVersion.VERSION_1_8\n',
        'pubspec.yaml':
            'name: a\nenvironment:\n  sdk: ^2.19.0\ndependencies:\n  http: '
                '^0.12.2\n',
      };
    });

    test('applies every field of a candidate', () async {
      final skipped = await const Materializer().apply(
        Candidate(
          gradle: Version(9, 1, 0),
          agp: Version(9, 0, 1),
          kotlin: Version(2, 3, 20),
          gradleProperties: const {'android.builtInKotlin': 'false'},
          minSdk: 24,
          compileSdk: 36,
          jvmTarget: 17,
          widenSdkFor: Version(3, 12, 2),
          constraints: const {'http': '^1.6.0'},
        ),
        legacySnapshot(),
        read: read,
        write: write,
      );
      expect(skipped, isEmpty);
      expect(files['android/settings.gradle'], contains('"9.0.1"'));
      expect(files['android/settings.gradle'], contains('"2.3.20"'));
      expect(
        files['android/gradle/wrapper/gradle-wrapper.properties'],
        contains('9.1.0'),
      );
      expect(
        files['android/gradle.properties'],
        'android.builtInKotlin=false\n',
      );
      expect(files['android/app/build.gradle'], contains('minSdk = 24'));
      expect(files['android/app/build.gradle'], contains('compileSdk = 36'));
      expect(files['android/app/build.gradle'], contains('VERSION_17'));
      expect(files['pubspec.yaml'], contains('http: ^1.6.0'));
      expect(files['pubspec.yaml'], contains('<4.0.0'));
    });

    test('reports edits it cannot apply', () async {
      files.remove('android/gradle/wrapper/gradle-wrapper.properties');
      files['android/settings.gradle'] = 'nothing here';
      final skipped = await const Materializer().apply(
        Candidate(
          gradle: Version(9, 1, 0),
          agp: Version(9, 0, 1),
          iosPlatform: Version(13, 0, 0),
          constraints: const {'local_pkg': '^1.0.0'},
        ),
        legacySnapshot(),
        read: read,
        write: write,
      );
      expect(skipped, [
        'Gradle: android/gradle/wrapper/gradle-wrapper.properties not found',
        'AGP: not declared in android/settings.gradle',
        'IPHONEOS_DEPLOYMENT_TARGET: ios/Runner.xcodeproj/project.pbxproj not found',
        'local_pkg: not declared in pubspec.yaml',
      ]);
    });
  });
}
