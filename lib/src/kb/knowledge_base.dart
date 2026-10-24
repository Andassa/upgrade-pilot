import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

/// Thrown when KB data is malformed or fails its integrity check.
final class KnowledgeBaseException implements Exception {
  KnowledgeBaseException(this.message);

  final String message;

  @override
  String toString() => 'Knowledge base: $message';
}

Version? _version(Object? raw) {
  if (raw == null || raw == 'unknown') return null;
  return parseLooseVersion('$raw');
}

Version _requiredVersion(JsonReader json, String key) {
  final value = _version(json[key]);
  if (value == null) throw FormatException('"$key" must be a version');
  return value;
}

/// Error and warning thresholds enforced by Flutter's Gradle plugin.
typedef Threshold = ({Version? error, Version? warn});

Threshold _threshold(JsonReader json) =>
    (error: _version(json['error']), warn: _version(json['warn']));

/// What a Flutter minor release expects from the Android/iOS toolchain.
@immutable
final class FlutterToolchain {
  const FlutterToolchain({
    required this.minor,
    required this.sampledVersion,
    required this.gradle,
    required this.agp,
    required this.kotlin,
    required this.java,
    required this.sources,
    required this.retrievedAt,
    this.dart,
    this.templateGradle,
    this.templateAgp,
    this.templateKotlin,
    this.templateGradleProperties = const {},
    this.compileSdk,
    this.minSdk,
    this.targetSdk,
    this.iosTemplatePlatform,
    this.iosMinimumSupported,
  });

  factory FlutterToolchain.fromJson(JsonReader json) {
    final template = json.object('template');
    final minimum = json.object('minimum');
    final android = json.object('android');
    final ios = json.object('ios');
    return FlutterToolchain(
      minor: json.string('minor'),
      sampledVersion: _requiredVersion(json, 'sampledVersion'),
      dart: _version(json['dart']),
      templateGradle: _version(template['gradle']),
      templateAgp: _version(template['agp']),
      templateKotlin: _version(template['kotlin']),
      templateGradleProperties: json
          .optionalObject('templateGradleProperties')
          .json
          .map((k, v) => MapEntry(k, '$v')),
      gradle: _threshold(minimum.object('gradle')),
      agp: _threshold(minimum.object('agp')),
      kotlin: _threshold(minimum.object('kotlin')),
      java: _threshold(minimum.object('java')),
      compileSdk: android.optionalInt('compileSdk'),
      minSdk: android.optionalInt('minSdk'),
      targetSdk: android.optionalInt('targetSdk'),
      iosTemplatePlatform: _version(ios['templatePodfilePlatform']),
      iosMinimumSupported: _version(ios['minimumSupported']),
      sources: json.strings('sources'),
      retrievedAt: json.string('retrievedAt'),
    );
  }

  final String minor;
  final Version sampledVersion;
  final Version? dart;
  final Version? templateGradle;
  final Version? templateAgp;
  final Version? templateKotlin;
  final Map<String, String> templateGradleProperties;
  final Threshold gradle;
  final Threshold agp;
  final Threshold kotlin;
  final Threshold java;
  final int? compileSdk;
  final int? minSdk;
  final int? targetSdk;
  final Version? iosTemplatePlatform;
  final Version? iosMinimumSupported;
  final List<String> sources;
  final String retrievedAt;
}

/// A sourced compatibility table.
@immutable
final class SourcedTable<T> {
  const SourcedTable(this.rows, this.source, this.retrievedAt);

  final List<T> rows;
  final String source;
  final String retrievedAt;
}

typedef AgpGradleRow = ({Version agp, Version gradle});
typedef JavaGradleRow = ({int java, Version minGradle, Version? maxExclusive});
typedef CompileSdkAgpRow = ({int api, Version agp});

/// Gradle versions able to run on a given JDK.
typedef GradleRange = ({Version min, Version? maxExclusive});

/// Sourced compatibility data. Unknown values are `null`, never guessed.
@immutable
final class KnowledgeBase {
  const KnowledgeBase({
    required this.kbVersion,
    required this.flutter,
    required this.agpMinGradle,
    required this.javaGradle,
    required this.compileSdkMinAgp,
    required this.sha256,
  });

  factory KnowledgeBase.parse(String content, {required String sha256}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (e) {
      throw KnowledgeBaseException('invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw KnowledgeBaseException('expected a JSON object');
    }
    final json = JsonReader(decoded);
    if (json['schemaVersion'] != supportedSchema) {
      throw KnowledgeBaseException(
        'unsupported schemaVersion ${json['schemaVersion']}',
      );
    }
    SourcedTable<T> table<T>(String key, T Function(JsonReader) row) {
      final t = json.object(key);
      return SourcedTable(
        t.objects('rows').map(row).toList(growable: false),
        t.string('source'),
        t.string('retrievedAt'),
      );
    }

    try {
      return KnowledgeBase(
        kbVersion: json.string('kbVersion'),
        sha256: sha256,
        flutter: json
            .objects('flutter')
            .map(FlutterToolchain.fromJson)
            .toList(growable: false),
        agpMinGradle: table(
          'agpMinGradle',
          (r) => (
            agp: _requiredVersion(r, 'agp'),
            gradle: _requiredVersion(r, 'gradle'),
          ),
        ),
        javaGradle: table('javaGradle', (r) {
          final max = r.optionalString('maxGradle');
          return (
            java: r.integer('java'),
            minGradle: _requiredVersion(r, 'minGradle'),
            maxExclusive: max == null ? null : _wildcardUpperBound(max),
          );
        }),
        compileSdkMinAgp: table(
          'compileSdkMinAgp',
          (r) => (api: r.integer('api'), agp: _requiredVersion(r, 'agp')),
        ),
      );
    } on FormatException catch (e) {
      throw KnowledgeBaseException('unexpected structure: ${e.message}');
    }
  }

  static const supportedSchema = 1;

  final String kbVersion;
  final String sha256;
  final List<FlutterToolchain> flutter;
  final SourcedTable<AgpGradleRow> agpMinGradle;
  final SourcedTable<JavaGradleRow> javaGradle;
  final SourcedTable<CompileSdkAgpRow> compileSdkMinAgp;

  /// The entry for the minor release of [version], or `null` if the KB
  /// does not cover it.
  FlutterToolchain? forFlutter(Version version) {
    final key = minorKey(version);
    for (final entry in flutter) {
      if (entry.minor == key) return entry;
    }
    return null;
  }

  /// Minimum Gradle required by [agp], or `null` when not documented.
  Version? minGradleForAgp(Version agp) {
    final key = minorKey(agp);
    for (final row in agpMinGradle.rows) {
      if (minorKey(row.agp) == key) return row.gradle;
    }
    return null;
  }

  /// Gradle versions that can run on JDK [java], or `null` when unknown.
  GradleRange? gradleRangeForJava(int java) {
    for (final row in javaGradle.rows) {
      if (row.java == java) {
        return (min: row.minGradle, maxExclusive: row.maxExclusive);
      }
    }
    return null;
  }

  /// Minimum AGP for a `compileSdk`, or `null` when not documented.
  Version? minAgpForCompileSdk(int api) {
    for (final row in compileSdkMinAgp.rows) {
      if (row.api == api) return row.agp;
    }
    return null;
  }
}

Version _wildcardUpperBound(String raw) {
  final parts = raw.split('.');
  if (parts.length == 3 && parts[2] == 'x') {
    return Version(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
  }
  final version = _version(raw);
  if (version == null) throw FormatException('invalid version "$raw"');
  return version;
}
