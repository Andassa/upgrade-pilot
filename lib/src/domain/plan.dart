import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/release.dart';

/// Overall result of `plan`.
enum Verdict {
  /// Every executed step passed.
  verified,

  /// The build passed, with warnings (analyzer issues...).
  verifiedWithWarnings,

  /// At least one blocking problem has no verified solution.
  blocked,
}

/// A direct dependency whose constraint or resolved version changes.
@immutable
final class DependencyUpdate {
  const DependencyUpdate({
    required this.name,
    this.fromConstraint,
    this.toConstraint,
    this.fromVersion,
    this.toVersion,
  });

  factory DependencyUpdate.fromJson(JsonReader json) => DependencyUpdate(
        name: json.string('name'),
        fromConstraint: json.optionalString('fromConstraint'),
        toConstraint: json.optionalString('toConstraint'),
        fromVersion: json.optionalString('fromVersion'),
        toVersion: json.optionalString('toVersion'),
      );

  final String name;
  final String? fromConstraint;
  final String? toConstraint;
  final String? fromVersion;
  final String? toVersion;

  /// The constraint in `pubspec.yaml` must be edited.
  bool get constraintChanged => fromConstraint != toConstraint;

  Map<String, Object?> toJson() => {
        'name': name,
        'fromConstraint': fromConstraint,
        'toConstraint': toConstraint,
        'fromVersion': fromVersion,
        'toVersion': toVersion,
      };
}

/// A problem without a verified solution.
@immutable
final class BlockedItem {
  const BlockedItem({
    required this.subject,
    required this.reason,
    this.suggestion,
    this.findingId,
  });

  factory BlockedItem.fromJson(JsonReader json) => BlockedItem(
        subject: json.string('subject'),
        reason: json.string('reason'),
        suggestion: json.optionalString('suggestion'),
        findingId: json.optionalString('findingId'),
      );

  /// e.g. `flutter_foo 2.1.0`.
  final String subject;
  final String reason;

  /// Never verified by a build. Always displayed as such.
  final String? suggestion;
  final String? findingId;

  Map<String, Object?> toJson() => {
        'subject': subject,
        'reason': reason,
        'suggestion': suggestion,
        'suggestionVerified': false,
        'findingId': findingId,
      };
}

/// One iteration of the verification loop.
@immutable
final class AttemptRecord {
  const AttemptRecord({
    required this.number,
    required this.description,
    required this.succeeded,
    this.findingId,
  });

  factory AttemptRecord.fromJson(JsonReader json) => AttemptRecord(
        number: json.integer('number'),
        description: json.string('description'),
        succeeded: json.boolean('succeeded'),
        findingId: json.optionalString('findingId'),
      );

  final int number;

  /// What this attempt changed, e.g. `AGP 8.5.0 → 8.9.1, Gradle 8.7 → 8.11`.
  final String description;
  final bool succeeded;
  final String? findingId;

  Map<String, Object?> toJson() => {
        'number': number,
        'description': description,
        'succeeded': succeeded,
        'findingId': findingId,
      };
}

@immutable
final class PlanProject {
  const PlanProject({
    required this.name,
    required this.displayPath,
    required this.fingerprint,
    this.gitCommit,
    this.flutterVersion,
  });

  factory PlanProject.fromJson(JsonReader json) => PlanProject(
        name: json.string('name'),
        displayPath: json.string('path'),
        fingerprint: json.string('fingerprint'),
        gitCommit: json.optionalString('gitCommit'),
        flutterVersion: json.optionalString('flutterVersion'),
      );

  final String name;

  /// Redacted path (home replaced by `~`).
  final String displayPath;

  /// SHA-256 over the files a plan may change.
  final String fingerprint;
  final String? gitCommit;

  /// The Flutter version the project used before the upgrade, if known.
  final String? flutterVersion;

  Map<String, Object?> toJson() => {
        'name': name,
        'path': displayPath,
        'fingerprint': fingerprint,
        'gitCommit': gitCommit,
        'flutterVersion': flutterVersion,
      };
}

/// The verified upgrade plan. Serialized as versioned JSON.
@immutable
final class Plan {
  const Plan({
    required this.toolVersion,
    required this.kbVersion,
    required this.createdAt,
    required this.project,
    required this.target,
    required this.sdkSource,
    required this.platforms,
    required this.changes,
    required this.manualSteps,
    required this.dependencyUpdates,
    required this.blocked,
    required this.evidence,
    required this.attempts,
    required this.findings,
    required this.notVerified,
    required this.verdict,
    required this.totalDuration,
  });

  /// Throws [FormatException] when [json] is not a supported plan.
  factory Plan.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    if (r['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported plan schemaVersion: ${r['schemaVersion']}',
      );
    }
    List<T> list<T>(String key, T Function(JsonReader) read) =>
        r.objects(key).map(read).toList(growable: false);
    return Plan(
      toolVersion: r.string('toolVersion'),
      kbVersion: r.string('kbVersion'),
      createdAt: DateTime.parse(r.string('createdAt')),
      project: PlanProject.fromJson(r.object('project')),
      target: FlutterRelease.fromJson(r.object('target')),
      sdkSource: r.string('sdkSource'),
      platforms: r.strings('platforms'),
      changes: list('changes', Change.fromJson),
      manualSteps: list('manualSteps', ManualStep.fromJson),
      dependencyUpdates: list('dependencyUpdates', DependencyUpdate.fromJson),
      blocked: list('blocked', BlockedItem.fromJson),
      evidence: list('evidence', Evidence.fromJson),
      attempts: list('attempts', AttemptRecord.fromJson),
      findings: list('findings', Finding.fromJson),
      notVerified: list('notVerified', NotVerified.fromJson),
      verdict: enumByName(Verdict.values, r.string('verdict')),
      totalDuration: Duration(milliseconds: r.integer('totalDurationMs')),
    );
  }

  /// Bumped on any breaking change of the JSON layout.
  static const schemaVersion = 1;

  final String toolVersion;
  final String kbVersion;
  final DateTime createdAt;
  final PlanProject project;
  final FlutterRelease target;

  /// How the target SDK was obtained: `global`, `fvm`, `cache`, `download`.
  final String sdkSource;
  final List<String> platforms;
  final List<Change> changes;
  final List<ManualStep> manualSteps;
  final List<DependencyUpdate> dependencyUpdates;
  final List<BlockedItem> blocked;
  final List<Evidence> evidence;
  final List<AttemptRecord> attempts;
  final List<Finding> findings;
  final List<NotVerified> notVerified;
  final Verdict verdict;
  final Duration totalDuration;

  bool get isApplicable => verdict != Verdict.blocked && changes.isNotEmpty;

  /// Evidence of the last (deciding) attempt only.
  List<Evidence> get finalEvidence {
    if (evidence.isEmpty) return const [];
    final last = evidence.last.attempt;
    return evidence.where((e) => e.attempt == last).toList(growable: false);
  }

  Finding? finding(String id) {
    for (final f in findings) {
      if (f.id == id) return f;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'toolVersion': toolVersion,
        'kbVersion': kbVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'project': project.toJson(),
        'target': target.toJson(),
        'sdkSource': sdkSource,
        'platforms': platforms,
        'verdict': verdict.name,
        'totalDurationMs': totalDuration.inMilliseconds,
        'changes': [for (final c in changes) c.toJson()],
        'manualSteps': [for (final s in manualSteps) s.toJson()],
        'dependencyUpdates': [for (final d in dependencyUpdates) d.toJson()],
        'blocked': [for (final b in blocked) b.toJson()],
        'attempts': [for (final a in attempts) a.toJson()],
        'evidence': [for (final e in evidence) e.toJson()],
        'findings': [for (final f in findings) f.toJson()],
        'notVerified': [for (final n in notVerified) n.toJson()],
      };
}
