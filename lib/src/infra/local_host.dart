import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// [Host] backed by `dart:io`.
final class LocalHost implements Host {
  LocalHost({Map<String, String>? environment})
      : environment = environment ?? Platform.environment;

  @override
  final Map<String, String> environment;

  @override
  String get os => Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
          ? 'windows'
          : 'linux';

  @override
  String get architecture => switch (Abi.current()) {
        Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
        _ => 'x64',
      };

  @override
  String get homeDirectory =>
      environment['HOME'] ??
      environment['USERPROFILE'] ??
      Directory.current.path;

  @override
  String get cacheDirectory {
    final override = environment['UPGRADE_PILOT_CACHE'];
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isWindows) {
      final local = environment['LOCALAPPDATA'];
      if (local != null) return p.join(local, 'upgrade-pilot', 'Cache');
    }
    final xdg = environment['XDG_CACHE_HOME'];
    final base =
        xdg != null && xdg.isNotEmpty ? xdg : p.join(homeDirectory, '.cache');
    return p.join(base, 'upgrade-pilot');
  }

  @override
  String get temporaryDirectory => Directory.systemTemp.path;

  @override
  String get currentDirectory => Directory.current.path;

  @override
  int get processors => Platform.numberOfProcessors;
}
