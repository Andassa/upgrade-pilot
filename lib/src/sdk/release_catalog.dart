import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/release.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Thrown when the release list is unavailable or a version is unknown.
final class ReleaseCatalogException implements Exception {
  ReleaseCatalogException(this.message, {this.offline = false});

  final String message;
  final bool offline;

  @override
  String toString() => message;
}

/// The official list of Flutter releases for the host platform.
@immutable
final class ReleaseIndex {
  const ReleaseIndex({
    required this.baseUrl,
    required this.currentHashes,
    required this.releases,
    required this.fromCache,
    this.fetchedAt,
    this.fallback = false,
  });

  /// Parses `releases_<os>.json`, keeping one archive per version (the one
  /// matching [architecture] when several exist).
  factory ReleaseIndex.parse(
    String body, {
    required String architecture,
    required bool fromCache,
    DateTime? fetchedAt,
  }) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('expected a JSON object');
    }
    final json = JsonReader(decoded);
    final byKey = <String, (FlutterRelease, String?)>{};
    for (final r in json.objects('releases')) {
      final rawVersion = r.optionalString('version');
      final version = parseLooseVersion(rawVersion?.split(' ').first);
      final date = DateTime.tryParse(r.optionalString('release_date') ?? '');
      if (version == null || date == null) continue;
      final channel = r.string('channel');
      final arch = r.optionalString('dart_sdk_arch');
      final release = FlutterRelease(
        version: version,
        channel: channel,
        hash: r.string('hash'),
        releaseDate: date,
        dartVersion: parseLooseVersion(
          r.optionalString('dart_sdk_version')?.split(' ').first,
        ),
        archive: r.optionalString('archive'),
        sha256: r.optionalString('sha256'),
      );
      final key = '$channel/${shortVersion(version)}';
      final existing = byKey[key];
      if (existing == null ||
          (existing.$2 != architecture && arch == architecture)) {
        byKey[key] = (release, arch);
      }
    }
    final releases = byKey.values.map((e) => e.$1).toList()
      ..sort((a, b) => b.releaseDate.compareTo(a.releaseDate));
    return ReleaseIndex(
      baseUrl: json.string('base_url'),
      currentHashes: json
          .optionalObject('current_release')
          .json
          .map((k, v) => MapEntry(k, '$v')),
      releases: releases,
      fromCache: fromCache,
      fetchedAt: fetchedAt,
    );
  }

  final String baseUrl;

  /// Channel → framework hash of the current release.
  final Map<String, String> currentHashes;

  /// Newest first.
  final List<FlutterRelease> releases;
  final bool fromCache;
  final DateTime? fetchedAt;

  /// Served from cache because the network was unavailable or `--offline`
  /// was used: the list may be outdated.
  final bool fallback;

  ReleaseIndex asFallback() => ReleaseIndex(
        baseUrl: baseUrl,
        currentHashes: currentHashes,
        releases: releases,
        fromCache: true,
        fetchedAt: fetchedAt,
        fallback: true,
      );

  /// Resolves `stable`, `beta`, `latest`, `3.44` or `3.44.9`.
  FlutterRelease resolve(String spec) {
    final normalized = spec.trim().toLowerCase();
    if (normalized == 'stable' || normalized == 'beta') {
      final hash = currentHashes[normalized];
      for (final r in releases) {
        if (r.hash == hash && r.channel == normalized) return r;
      }
      throw ReleaseCatalogException('No current $normalized release found.');
    }
    if (normalized == 'latest') {
      for (final r in releases) {
        if (r.channel == 'stable' || r.channel == 'beta') return r;
      }
      throw ReleaseCatalogException('No release found.');
    }
    final minorOnly = RegExp(r'^v?(\d+)\.(\d+)$').firstMatch(normalized);
    if (minorOnly != null) {
      final major = int.parse(minorOnly.group(1)!);
      final minor = int.parse(minorOnly.group(2)!);
      for (final r in releases) {
        if (r.channel == 'stable' &&
            r.version.major == major &&
            r.version.minor == minor) {
          return r;
        }
      }
      throw ReleaseCatalogException('No stable release $spec.x found.');
    }
    final version = parseLooseVersion(normalized);
    if (version == null) {
      throw ReleaseCatalogException('"$spec" is not a Flutter version.');
    }
    FlutterRelease? match;
    for (final r in releases) {
      if (r.version != version) continue;
      if (r.channel == 'stable') return r;
      match ??= r;
    }
    if (match != null) return match;
    throw ReleaseCatalogException('Flutter $spec is not an official release.');
  }

  /// The archive URL of [release], or `null` without archive.
  Uri? archiveUri(FlutterRelease release) =>
      release.archive == null ? null : Uri.parse('$baseUrl/${release.archive}');

  FlutterRelease? byVersion(Version version) {
    for (final r in releases) {
      if (r.version == version) return r;
    }
    return null;
  }
}

/// Downloads and caches the official release list.
final class ReleaseCatalog {
  ReleaseCatalog({
    required HttpPort http,
    required FileSystem fs,
    required Host host,
    required Clock clock,
    this.ttl = const Duration(hours: 6),
  })  : _http = http,
        _fs = fs,
        _host = host,
        _clock = clock;

  final HttpPort _http;
  final FileSystem _fs;
  final Host _host;
  final Clock _clock;
  final Duration ttl;

  Uri get uri => Uri.parse(
        'https://storage.googleapis.com/flutter_infra_release/releases/'
        'releases_${_host.os}.json',
      );

  String get _cachePath =>
      p.join(_host.cacheDirectory, 'releases', 'releases_${_host.os}.json');
  String get _stampPath => '$_cachePath.fetched';

  Future<ReleaseIndex> load({bool offline = false}) async {
    final cached = await _fs.readString(_cachePath);
    final stamp = DateTime.tryParse(await _fs.readString(_stampPath) ?? '');
    final fresh = stamp != null && _clock().difference(stamp) < ttl;
    if (cached != null && fresh) {
      return _parse(cached, fromCache: true, fetchedAt: stamp);
    }
    if (cached != null && offline) {
      return _parse(cached, fromCache: true, fetchedAt: stamp).asFallback();
    }
    if (offline) {
      throw ReleaseCatalogException(
        'The Flutter release list is not cached yet.',
        offline: true,
      );
    }
    try {
      final reply = await _http.get(uri);
      if (!reply.ok) {
        throw NetworkException('HTTP ${reply.statusCode}', uri: uri);
      }
      final body = utf8.decode(reply.body);
      final index = _parse(body, fromCache: false, fetchedAt: _clock());
      await _fs.writeString(_cachePath, body);
      await _fs.writeString(_stampPath, _clock().toUtc().toIso8601String());
      return index;
    } on NetworkException {
      if (cached != null) {
        return _parse(cached, fromCache: true, fetchedAt: stamp).asFallback();
      }
      rethrow;
    }
  }

  ReleaseIndex _parse(
    String body, {
    required bool fromCache,
    DateTime? fetchedAt,
  }) {
    try {
      return ReleaseIndex.parse(
        body,
        architecture: _host.architecture,
        fromCache: fromCache,
        fetchedAt: fetchedAt,
      );
    } on FormatException catch (e) {
      throw ReleaseCatalogException('Invalid release list: ${e.message}');
    }
  }
}
