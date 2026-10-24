import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

/// An official Flutter SDK release, as published in
/// `releases_<os>.json` by the Flutter team.
@immutable
final class FlutterRelease {
  const FlutterRelease({
    required this.version,
    required this.channel,
    required this.hash,
    required this.releaseDate,
    this.dartVersion,
    this.archive,
    this.sha256,
  });

  factory FlutterRelease.fromJson(JsonReader json) {
    final version = parseLooseVersion(json.string('version'));
    if (version == null) throw const FormatException('invalid "version"');
    return FlutterRelease(
      version: version,
      channel: json.string('channel'),
      hash: json.string('hash'),
      releaseDate: DateTime.parse(json.string('releaseDate')),
      dartVersion: parseLooseVersion(json.optionalString('dartVersion')),
      archive: json.optionalString('archive'),
      sha256: json.optionalString('sha256'),
    );
  }

  final Version version;
  final String channel;

  /// Framework git revision.
  final String hash;
  final DateTime releaseDate;
  final Version? dartVersion;

  /// Archive path relative to the release base URL.
  final String? archive;

  /// SHA-256 of the archive, when published.
  final String? sha256;

  Map<String, Object?> toJson() => {
        'version': shortVersion(version),
        'channel': channel,
        'hash': hash,
        'releaseDate': releaseDate.toUtc().toIso8601String(),
        'dartVersion': dartVersion == null ? null : shortVersion(dartVersion!),
        'archive': archive,
        'sha256': sha256,
      };
}
