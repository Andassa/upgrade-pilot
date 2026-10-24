import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/cli/services.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

import '../unit/diagnose/samples.dart';
import '../unit/sdk/sdk_test.dart' show releasesJson, releasesUrl;
import 'fakes.dart';

const projectRoot = '/work/legacy_app';

const legacyFiles = {
  'pubspec.yaml': '''
name: legacy_app
environment:
  sdk: ^3.5.4
dependencies:
  flutter:
    sdk: flutter
  http: ^0.12.2
''',
  'lib/main.dart': 'void main() {}\n',
  'android/settings.gradle': '''
plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "8.1.0" apply false
    id "org.jetbrains.kotlin.android" version "1.8.22" apply false
}
''',
  'android/gradle/wrapper/gradle-wrapper.properties':
      r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.3-all.zip'
          '\n',
  'android/gradle.properties':
      'android.useAndroidX=true\nMYAPP_STORE_PASSWORD=hunter2\n',
  'android/app/build.gradle': '''
plugins {
    id "com.android.application"
    id "kotlin-android"
}
android {
    compileSdk = flutter.compileSdkVersion
    defaultConfig {
        minSdk = flutter.minSdkVersion
    }
}
''',
  'android/key.properties': 'storePassword=hunter2\nkeyPassword=hunter2\n',
  '.env': 'API_TOKEN=sk-livefakefakefakefakefakefake\n',
};

/// A machine with Flutter 3.44.9 installed globally, a JDK 25, an Android
/// SDK, and a scripted `flutter` reproducing real outputs.
final class Scenario {
  Scenario({this.console}) {
    fs
      ..addTree(projectRoot, legacyFiles)
      ..addFile('/opt/flutter/bin/flutter', '')
      ..addFile(
        '/opt/flutter/bin/cache/flutter.version.json',
        '{"frameworkVersion": "3.44.9"}',
      )
      ..addFile('/opt/android-studio/jbr/bin/java', '')
      ..addFile('/home/dev/Android/Sdk/platforms/android-36/x', '');
    http
      ..json(releasesUrl, releasesJson())
      ..json('https://pub.dev/api/packages/http', {
        'name': 'http',
        'versions': [
          {
            'version': '1.6.0',
            'pubspec': {
              'environment': {'sdk': '^3.4.0'},
            },
          },
        ],
      });
    runner
      ..on(
        'java',
        (_) => outcome(stderr: 'openjdk version "25.0.3" 2025-10-21'),
      )
      ..on('git', (c) => outcome(exitCode: 128, stderr: 'not a git repository'))
      ..on('pub get', (c) async {
        final pubspec =
            fs.text(p.posix.join(c.workingDirectory!, 'pubspec.yaml'))!;
        if (pubspec.contains('^0.12.2')) {
          return outcome(exitCode: 1, stdout: ruleSamples['UP-PUB-0002']!.$2);
        }
        await fs.writeString(
          p.posix.join(c.workingDirectory!, 'pubspec.lock'),
          'packages:\n  http:\n    dependency: "direct main"\n    source: '
          'hosted\n    version: "1.6.0"\n',
        );
        return outcome(duration: const Duration(seconds: 9));
      })
      ..on('analyze', (_) => outcome(stdout: 'No issues found!'))
      ..on('build apk', (c) {
        final props = fs.text(
              p.posix.join(c.workingDirectory!, 'android/gradle.properties'),
            ) ??
            '';
        final settings = fs.text(
          p.posix.join(c.workingDirectory!, 'android/settings.gradle'),
        )!;
        if (buildLog != null) return outcome(exitCode: 1, stdout: buildLog!);
        if (settings.contains('"9.0.1"') &&
            !props.contains('android.builtInKotlin=false')) {
          return outcome(exitCode: 1, stdout: ruleSamples['UP-AND-0007']!.$2);
        }
        if (settings.contains('"8.11.1"')) {
          return outcome(
            exitCode: 1,
            stdout: '* What went wrong:\nSomething nobody knows\n',
          );
        }
        return outcome(duration: const Duration(seconds: 52));
      });
  }

  final fs = MemoryFileSystem();
  final http = FakeHttp();
  final runner = FakeProcessRunner(
    onPath: {'flutter': '/opt/flutter/bin/flutter', 'git': '/usr/bin/git'},
  );
  final host = FakeHost(
    currentDirectory: projectRoot,
    environment: {
      'PATH': '/opt/flutter/bin:/usr/bin',
      'HOME': '/home/dev',
      'GITHUB_TOKEN': 'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
    },
  );
  final FakeConsole? console;

  /// When set, every `flutter build apk` fails with this output.
  String? buildLog;

  Services services({Console? console}) => Services(
        fs: fs,
        runner: runner,
        http: http,
        host: host,
        clock: steppingClock(DateTime.utc(2026, 10, 24, 9)),
        console: console ?? this.console ?? FakeConsole(),
      );
}
