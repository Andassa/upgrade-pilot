import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Detects platform toolchains without modifying anything.
final class ToolchainProbe {
  ToolchainProbe({
    required FileSystem fs,
    required ProcessRunner runner,
    required Host host,
  })  : _fs = fs,
        _runner = runner,
        _host = host;

  final FileSystem _fs;
  final ProcessRunner _runner;
  final Host _host;

  Map<String, String> get _env => {
        if (_host.environment['PATH'] case final path?) 'PATH': path,
        if (_host.environment['HOME'] case final home?) 'HOME': home,
        if (_host.environment['DEVELOPER_DIR'] case final dir?)
          'DEVELOPER_DIR': dir,
        if (_host.environment['LANG'] case final lang?) 'LANG': lang,
      };

  /// The Android SDK directory, as Flutter would find it.
  Future<String?> androidSdk() async {
    final env = _host.environment;
    final home = _host.homeDirectory;
    final settings = await _fs.readString(
      p.join(
        env['XDG_CONFIG_HOME'] ?? p.join(home, '.config'),
        'flutter',
        'settings',
      ),
    );
    String? configured;
    if (settings != null) {
      try {
        final decoded = jsonDecode(settings);
        if (decoded is Map<String, Object?> &&
            decoded['android-sdk'] is String) {
          configured = decoded['android-sdk']! as String;
        }
      } on FormatException {
        configured = null;
      }
    }
    final candidates = [
      if (configured != null) configured,
      if (env['ANDROID_HOME'] case final androidHome?) androidHome,
      if (env['ANDROID_SDK_ROOT'] case final sdkRoot?) sdkRoot,
      switch (_host.os) {
        'macos' => p.join(home, 'Library', 'Android', 'sdk'),
        'windows' => p.join(env['LOCALAPPDATA'] ?? home, 'Android', 'Sdk'),
        _ => p.join(home, 'Android', 'Sdk'),
      },
    ];
    for (final dir in candidates) {
      if (dir.isNotEmpty && await _fs.isDirectory(p.join(dir, 'platforms'))) {
        return dir;
      }
    }
    return null;
  }

  Future<String?> _firstLine(String executable, List<String> args) async {
    if (await _runner.which(executable) == null) return null;
    try {
      final outcome = await _runner.run(
        Command(
          executable,
          args,
          environment: _env,
          timeout: const Duration(seconds: 30),
        ),
      );
      if (!outcome.succeeded) return null;
      final line = outcome.stdout.trim().split('\n').first.trim();
      return line.isEmpty ? null : line;
    } on ProcessStartException {
      return null;
    }
  }

  /// e.g. `Xcode 27.0`, or `null` when Xcode is unusable or not on macOS.
  Future<String?> xcode() async =>
      _host.os == 'macos' ? _firstLine('xcodebuild', const ['-version']) : null;

  /// e.g. `1.16.2`.
  Future<String?> cocoapods() async =>
      _host.os == 'macos' ? _firstLine('pod', const ['--version']) : null;

  /// e.g. `git version 2.50.1`.
  Future<String?> git() => _firstLine('git', const ['--version']);
}
