import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/release.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sdk/release_catalog.dart';

/// Where the target SDK comes from. Global and FVM SDKs are used read-only.
enum SdkSource { global, fvm, cache, download }

/// A Flutter SDK ready to run.
@immutable
final class SdkHandle {
  const SdkHandle({
    required this.root,
    required this.flutter,
    required this.version,
    required this.source,
  });

  final String root;

  /// Absolute path of the `flutter` executable.
  final String flutter;
  final Version version;
  final SdkSource source;
}

final class SdkException implements Exception {
  SdkException(this.message, {this.environment = false});

  final String message;

  /// The problem comes from the machine (disk, network, tools).
  final bool environment;

  @override
  String toString() => message;
}

final class InsufficientDiskException implements Exception {
  InsufficientDiskException({required this.required, required this.available});

  final int required;
  final int available;
}

/// Finds or installs a Flutter SDK without touching the user's global
/// installation, `PATH` or configuration.
final class SdkManager {
  SdkManager({
    required FileSystem fs,
    required ProcessRunner runner,
    required HttpPort http,
    required Host host,
  })  : _fs = fs,
        _runner = runner,
        _http = http,
        _host = host;

  final FileSystem _fs;
  final ProcessRunner _runner;
  final HttpPort _http;
  final Host _host;

  /// Space needed to download and extract an SDK archive.
  static const int requiredBytes = 4 * 1024 * 1024 * 1024;
  static const _marker = '.upgrade-pilot-complete';

  String get _flutterName => _host.os == 'windows' ? 'flutter.bat' : 'flutter';
  String get sdksDirectory => p.join(_host.cacheDirectory, 'sdks');

  /// Reads the version of the SDK at [root] from its version files.
  Future<Version?> sdkVersion(String root) async {
    final json = await _fs.readString(
      p.join(root, 'bin', 'cache', 'flutter.version.json'),
    );
    if (json != null) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is Map<String, Object?>) {
          final v = decoded['frameworkVersion'] ?? decoded['flutterVersion'];
          if (v is String) return parseLooseVersion(v);
        }
      } on FormatException {
        // Fall through to the legacy file.
      }
    }
    final legacy = await _fs.readString(p.join(root, 'version'));
    return parseLooseVersion(legacy?.trim());
  }

  /// The Flutter SDK on the `PATH`, if any.
  Future<SdkHandle?> globalSdk() async {
    final found = await _runner.which('flutter');
    if (found == null) return null;
    final real = await _fs.canonicalize(found);
    final root = p.dirname(p.dirname(real));
    final version = await sdkVersion(root);
    if (version == null) return null;
    return SdkHandle(
      root: root,
      flutter: p.join(root, 'bin', _flutterName),
      version: version,
      source: SdkSource.global,
    );
  }

  /// An installed SDK for [version]: global, FVM or upgrade-pilot cache.
  Future<SdkHandle?> findInstalled(Version version) async {
    final global = await globalSdk();
    if (global != null && global.version == version) return global;
    final label = shortVersion(version);
    final env = _host.environment;
    final fvmRoots = [
      if (env['FVM_CACHE_PATH'] case final path? when path.isNotEmpty)
        p.join(path, 'versions'),
      p.join(_host.homeDirectory, 'fvm', 'versions'),
      p.join(_host.homeDirectory, '.fvm', 'versions'),
    ];
    for (final base in fvmRoots) {
      final root = p.join(base, label);
      if (await _fs.exists(p.join(root, 'bin', _flutterName)) &&
          await sdkVersion(root) == version) {
        return SdkHandle(
          root: root,
          flutter: p.join(root, 'bin', _flutterName),
          version: version,
          source: SdkSource.fvm,
        );
      }
    }
    final cached = p.join(sdksDirectory, label);
    if (await _fs.exists(p.join(cached, _marker))) {
      final root = p.join(cached, 'flutter');
      return SdkHandle(
        root: root,
        flutter: p.join(root, 'bin', _flutterName),
        version: version,
        source: SdkSource.cache,
      );
    }
    return null;
  }

  /// Returns an SDK for [release], downloading the official archive into
  /// the cache when needed. The archive checksum is verified when the
  /// release list publishes one.
  Future<SdkHandle> obtain(
    FlutterRelease release,
    ReleaseIndex index, {
    bool offline = false,
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    final installed = await findInstalled(release.version);
    if (installed != null) return installed;
    final label = shortVersion(release.version);
    if (offline) {
      throw SdkException(
        'Flutter $label is not installed and --offline forbids downloading.',
        environment: true,
      );
    }
    final uri = index.archiveUri(release);
    if (uri == null) {
      throw SdkException('Flutter $label has no downloadable archive.');
    }
    final free = await _fs.freeBytes(_host.cacheDirectory);
    if (free != null && free < requiredBytes) {
      throw InsufficientDiskException(required: requiredBytes, available: free);
    }
    final downloads = p.join(_host.cacheDirectory, 'downloads');
    final archive = p.join(downloads, p.basename(uri.path));
    final partial = '$archive.part';
    await _fs.deleteRecursive(partial);
    await _http.download(
      uri,
      partial,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    final expected = release.sha256;
    if (expected != null) {
      final actual = await _fs.sha256File(partial);
      if (actual != expected) {
        await _fs.deleteRecursive(partial);
        throw SdkException(
          'Checksum mismatch for ${p.basename(uri.path)}: the download is '
          'corrupted or was tampered with.',
        );
      }
    }
    await _fs.rename(partial, archive);
    final staging = await _fs.createPrivateTempDirectory(
      sdksDirectory,
      '.staging-',
    );
    try {
      final outcome = await _runner.run(
        _extractCommand(archive, staging),
        cancellation: cancellation,
      );
      if (!outcome.succeeded) {
        throw SdkException(
          'Could not extract ${p.basename(archive)}: ${outcome.stderr.trim()}',
          environment: true,
        );
      }
      final target = p.join(sdksDirectory, label);
      await _fs.deleteRecursive(target);
      await _fs.rename(staging, target);
      await _fs.writeString(p.join(target, _marker), uri.toString());
    } finally {
      await _fs.deleteRecursive(staging);
      await _fs.deleteRecursive(archive);
    }
    final root = p.join(sdksDirectory, label, 'flutter');
    return SdkHandle(
      root: root,
      flutter: p.join(root, 'bin', _flutterName),
      version: release.version,
      source: SdkSource.download,
    );
  }

  Command _extractCommand(String archive, String destination) {
    final env = {
      'PATH': _host.environment['PATH'] ?? '/usr/bin:/bin',
      if (_host.environment['SystemRoot'] case final root?) 'SystemRoot': root,
    };
    if (archive.endsWith('.tar.xz')) {
      return Command(
        'tar',
        ['-xJf', archive, '-C', destination],
        environment: env,
      );
    }
    if (_host.os == 'windows') {
      return Command(
        'tar',
        ['-xf', archive, '-C', destination],
        environment: env,
      );
    }
    return Command(
      'unzip',
      ['-q', '-o', archive, '-d', destination],
      environment: env,
    );
  }

  /// Installed upgrade-pilot SDKs (not global or FVM ones).
  Future<List<String>> cachedSdks() async => [
        for (final entry in await _fs.list(sdksDirectory))
          if (entry.type == EntryType.directory) entry.path,
      ];
}
