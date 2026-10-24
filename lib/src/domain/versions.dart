import 'package:pub_semver/pub_semver.dart';

final _loose = RegExp(
  r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.\d+)*(?:[-+]?([0-9A-Za-z][0-9A-Za-z.-]*))?$',
);

/// Parses the loose version strings used by build tools.
///
/// Accepts `8.3`, `8.10.2`, `9.1.0-rc-1`, `2.1.0-Beta1` or `v3.24.5`.
/// Returns `null` when [raw] is not a version.
Version? parseLooseVersion(String? raw) {
  if (raw == null) return null;
  final match = _loose.firstMatch(raw.trim());
  if (match == null) return null;
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2) ?? '0');
  final patch = int.parse(match.group(3) ?? '0');
  final suffix = match.group(4);
  if (suffix == null || suffix.isEmpty) return Version(major, minor, patch);
  final pre = suffix.replaceAll(RegExp('[^0-9A-Za-z.-]'), '');
  return Version(major, minor, patch, pre: pre.isEmpty ? null : pre);
}

/// Formats [version] the way Gradle names its distributions.
///
/// Gradle 8 drops a zero patch (`8.14`), Gradle 9 and later keep it
/// (`9.1.0`). Writing `8.14.0` produces a URL that does not exist.
String gradleDistributionVersion(Version version) {
  final pre =
      version.preRelease.isEmpty ? '' : '-${version.preRelease.join('.')}';
  if (version.major < 9 && version.patch == 0) {
    return '${version.major}.${version.minor}$pre';
  }
  return '${version.major}.${version.minor}.${version.patch}$pre';
}

/// Formats [version] without build metadata.
String shortVersion(Version version) {
  final pre =
      version.preRelease.isEmpty ? '' : '-${version.preRelease.join('.')}';
  return '${version.major}.${version.minor}.${version.patch}$pre';
}

/// Returns the larger of the non-null versions, or `null` if none.
Version? maxVersion(Iterable<Version?> versions) {
  Version? best;
  for (final v in versions) {
    if (v == null) continue;
    if (best == null || v > best) best = v;
  }
  return best;
}

/// The `major.minor` part of [version], e.g. `3.44`.
String minorKey(Version version) => '${version.major}.${version.minor}';
