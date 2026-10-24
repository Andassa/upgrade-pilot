import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// One published version of a package and its SDK constraints.
@immutable
final class PubVersion {
  const PubVersion({
    required this.version,
    required this.retracted,
    this.sdk,
    this.flutter,
  });

  final Version version;
  final bool retracted;
  final VersionConstraint? sdk;
  final VersionConstraint? flutter;
}

@immutable
final class PubPackage {
  const PubPackage({
    required this.name,
    required this.versions,
    required this.discontinued,
    this.replacedBy,
  });

  factory PubPackage.parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('expected a JSON object');
    }
    final json = JsonReader(decoded);
    VersionConstraint? constraint(Object? raw) {
      if (raw is! String) return null;
      try {
        return VersionConstraint.parse(raw);
      } on FormatException {
        return null;
      }
    }

    final versions = <PubVersion>[];
    for (final entry in json.objects('versions')) {
      final Version version;
      try {
        version = Version.parse(entry.string('version'));
      } on FormatException {
        continue;
      }
      final env = entry.optionalObject('pubspec').optionalObject('environment');
      versions.add(
        PubVersion(
          version: version,
          retracted: entry.boolean('retracted'),
          sdk: constraint(env['sdk']),
          flutter: constraint(env['flutter']),
        ),
      );
    }
    return PubPackage(
      name: json.string('name'),
      versions: versions,
      discontinued: json.boolean('isDiscontinued'),
      replacedBy: json.optionalString('replacedBy'),
    );
  }

  final String name;
  final List<PubVersion> versions;
  final bool discontinued;
  final String? replacedBy;
}

/// Dart 3 reads `<3.0.0` upper bounds of null-safe packages (lower bound
/// at least 2.12) as `<4.0.0`.
/// Source: https://dart.dev/resources/dart-3-migration
bool sdkAllows(VersionConstraint constraint, Version dart) {
  if (constraint.allows(dart)) return true;
  if (dart.major == 3 && constraint is VersionRange) {
    final min = constraint.min;
    final max = constraint.max;
    // pub_semver stores `<3.0.0` as `<3.0.0-0`, so ignore the pre-release.
    if (min != null &&
        min >= Version(2, 12, 0) &&
        max != null &&
        max.major == 3 &&
        max.minor == 0 &&
        max.patch == 0 &&
        !constraint.includeMax) {
      return VersionRange(
        min: min,
        includeMin: constraint.includeMin,
        max: Version(4, 0, 0),
      ).allows(dart);
    }
  }
  return false;
}

/// Pub ignores upper bounds of Flutter SDK constraints; only the lower
/// bound matters.
/// Source: https://dart.dev/tools/pub/pubspec#flutter-sdk-constraints
bool flutterAllows(VersionConstraint? constraint, Version flutter) {
  if (constraint == null) return true;
  if (constraint is VersionRange) {
    final min = constraint.min;
    if (min == null) return true;
    return constraint.includeMin ? flutter >= min : flutter > min;
  }
  return constraint.allows(flutter);
}

/// Read-only client for the pub.dev API, with a small disk cache.
final class PubDevClient {
  PubDevClient({
    required HttpPort http,
    required FileSystem fs,
    required Host host,
    required Clock clock,
    this.offline = false,
    this.ttl = const Duration(hours: 6),
  })  : _http = http,
        _fs = fs,
        _host = host,
        _clock = clock;

  final HttpPort _http;
  final FileSystem _fs;
  final Host _host;
  final Clock _clock;
  final bool offline;
  final Duration ttl;

  static final _name = RegExp(r'^[a-z][a-z0-9_]*$');

  String _cachePath(String name) =>
      p.join(_host.cacheDirectory, 'pub', '$name.json');

  /// Package metadata, or `null` if unknown or unreachable.
  Future<PubPackage?> package(String name) async {
    if (!_name.hasMatch(name)) return null;
    final path = _cachePath(name);
    final cached = await _fs.readString(path);
    final stamp =
        DateTime.tryParse(await _fs.readString('$path.fetched') ?? '');
    final fresh = stamp != null && _clock().difference(stamp) < ttl;
    if (cached != null && (offline || fresh)) return _parse(cached);
    if (offline) return null;
    try {
      final reply = await _http.get(
        Uri.parse('https://pub.dev/api/packages/$name'),
      );
      if (!reply.ok) return cached == null ? null : _parse(cached);
      final body = utf8.decode(reply.body);
      await _fs.writeString(path, body);
      await _fs.writeString(
        '$path.fetched',
        _clock().toUtc().toIso8601String(),
      );
      return _parse(body);
    } on NetworkException {
      return cached == null ? null : _parse(cached);
    }
  }

  PubPackage? _parse(String body) {
    try {
      return PubPackage.parse(body);
    } on FormatException {
      return null;
    }
  }

  /// Newest stable, non-retracted version usable with [dart] and
  /// [flutter], or `null` when there is none.
  Future<Version?> latestCompatible(
    String name, {
    required Version dart,
    required Version flutter,
  }) async {
    final info = await package(name);
    if (info == null) return null;
    final candidates = info.versions
        .where((v) => !v.version.isPreRelease && !v.retracted)
        .where((v) => v.sdk != null && sdkAllows(v.sdk!, dart))
        .where((v) => flutterAllows(v.flutter, flutter))
        .map((v) => v.version)
        .toList()
      ..sort();
    return candidates.isEmpty ? null : candidates.last;
  }
}
