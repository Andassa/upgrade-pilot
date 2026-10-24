import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// The JDK Flutter is expected to use for Gradle.
@immutable
final class JdkInfo {
  const JdkInfo({
    required this.executable,
    required this.major,
    required this.version,
    required this.origin,
  });

  final String executable;
  final int major;

  /// Full version string, e.g. `25.0.3`.
  final String version;

  /// `flutter config`, `Android Studio`, `JAVA_HOME` or `PATH`.
  final String origin;
}

final _versionLine = RegExp('version "([0-9][^"]*)"');

/// Parses `java -version` output and returns the major version.
int? parseJavaMajor(String output) {
  final raw = _versionLine.firstMatch(output)?.group(1);
  if (raw == null) return null;
  final parts = raw.split(RegExp('[._-]'));
  final first = int.tryParse(parts.first);
  if (first == 1 && parts.length > 1) return int.tryParse(parts[1]);
  return first;
}

/// Finds the JDK in the same order as the Flutter tool: `flutter config
/// --jdk-dir`, the JDK bundled with Android Studio, `JAVA_HOME`, `PATH`.
final class JdkLocator {
  JdkLocator({
    required FileSystem fs,
    required ProcessRunner runner,
    required Host host,
  })  : _fs = fs,
        _runner = runner,
        _host = host;

  final FileSystem _fs;
  final ProcessRunner _runner;
  final Host _host;

  String get _java => _host.os == 'windows' ? 'java.exe' : 'java';

  Future<List<(String, String)>> _candidates() async {
    final home = _host.homeDirectory;
    final env = _host.environment;
    final result = <(String, String)>[];
    for (final settings in [
      p.join(
        env['XDG_CONFIG_HOME'] ?? p.join(home, '.config'),
        'flutter',
        'settings',
      ),
      p.join(home, '.flutter_settings'),
      if (env['APPDATA'] case final appData?)
        p.join(appData, '.flutter_settings'),
    ]) {
      final content = await _fs.readString(settings);
      if (content == null) continue;
      try {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, Object?> && decoded['jdk-dir'] is String) {
          result.add((decoded['jdk-dir']! as String, 'flutter config'));
        }
      } on FormatException {
        continue;
      }
    }
    final studio = switch (_host.os) {
      'macos' => [
          '/Applications/Android Studio.app/Contents/jbr/Contents/Home',
          p.join(
            home,
            'Applications/Android Studio.app/Contents/jbr/Contents/Home',
          ),
        ],
      'windows' => [r'C:\Program Files\Android\Android Studio\jbr'],
      _ => [
          '/opt/android-studio/jbr',
          p.join(home, 'android-studio', 'jbr'),
          '/snap/android-studio/current/jbr',
        ],
    };
    for (final dir in studio) {
      result.add((dir, 'Android Studio'));
    }
    if (env['JAVA_HOME'] case final javaHome? when javaHome.isNotEmpty) {
      result.add((javaHome, 'JAVA_HOME'));
    }
    return result;
  }

  Future<JdkInfo?> locate() async {
    for (final (home, origin) in await _candidates()) {
      final executable = p.join(home, 'bin', _java);
      if (!await _fs.exists(executable)) continue;
      final info = await _probe(executable, origin);
      if (info != null) return info;
    }
    final onPath = await _runner.which('java');
    return onPath == null ? null : _probe(onPath, 'PATH');
  }

  Future<JdkInfo?> _probe(String executable, String origin) async {
    try {
      final outcome = await _runner.run(
        Command(
          executable,
          const ['-version'],
          environment: {'PATH': _host.environment['PATH'] ?? ''},
          timeout: const Duration(seconds: 20),
        ),
      );
      final major = parseJavaMajor(outcome.output);
      if (major == null) return null;
      return JdkInfo(
        executable: executable,
        major: major,
        version: _versionLine.firstMatch(outcome.output)!.group(1)!,
        origin: origin,
      );
    } on ProcessStartException {
      return null;
    }
  }
}
