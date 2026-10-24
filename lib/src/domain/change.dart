import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';

/// What kind of file a [Change] touches.
enum ChangeKind {
  pubspec,
  lockfile,
  gradleWrapper,
  gradleSettings,
  gradleBuild,
  gradleProperties,
  versionCatalog,
  podfile,
  xcodeProject,
  flutterPin,
}

/// A zero-context edit: replace [deleteCount] lines starting at line
/// index [start] (0-based) with [insert]. Only changed lines are stored,
/// so unrelated lines (which may hold secrets) never reach the cache.
@immutable
final class Hunk {
  const Hunk({
    required this.start,
    required this.deleteCount,
    required this.insert,
  });

  factory Hunk.fromJson(JsonReader json) => Hunk(
        start: json.integer('start'),
        deleteCount: json.integer('delete'),
        insert: json.strings('insert'),
      );

  final int start;
  final int deleteCount;
  final List<String> insert;

  Map<String, Object?> toJson() => {
        'start': start,
        'delete': deleteCount,
        'insert': insert,
      };
}

/// Splits content into lines; the last element is `''` when the content
/// ends with a newline, so joining with `\n` restores it exactly.
List<String> splitLines(String? content) =>
    content == null ? <String>[] : content.split('\n');

/// Applies [hunks] (computed against the same base) to [content].
String applyHunks(String? content, List<Hunk> hunks) {
  final lines = splitLines(content);
  final ordered = [...hunks]..sort((a, b) => b.start.compareTo(a.start));
  for (final hunk in ordered) {
    if (hunk.start > lines.length ||
        hunk.start + hunk.deleteCount > lines.length) {
      throw const FormatException('Hunk outside of the file');
    }
    lines.replaceRange(hunk.start, hunk.start + hunk.deleteCount, hunk.insert);
  }
  return lines.join('\n');
}

/// One file modification of a plan.
@immutable
final class Change {
  const Change({
    required this.path,
    required this.kind,
    required this.summary,
    required this.beforeSha256,
    required this.afterSha256,
    required this.hunks,
    required this.diff,
    this.generated = false,
  });

  factory Change.fromJson(JsonReader json) => Change(
        path: json.string('path'),
        kind: enumByName(ChangeKind.values, json.string('kind')),
        summary: json.string('summary'),
        beforeSha256: json.optionalString('beforeSha256'),
        afterSha256: json.string('afterSha256'),
        hunks: json.objects('hunks').map(Hunk.fromJson).toList(growable: false),
        diff: json.string('diff'),
        generated: json.boolean('generated'),
      );

  /// Path relative to the project root, with `/` separators.
  final String path;
  final ChangeKind kind;

  /// One-line human summary, e.g. `AGP 8.1.0 → 9.0.1`.
  final String summary;

  /// SHA-256 of the file when the plan was made; `null` for a new file.
  final String? beforeSha256;
  final String afterSha256;
  final List<Hunk> hunks;

  /// Redacted unified diff, for display only.
  final String diff;

  /// Produced by a tool (e.g. `pubspec.lock`) rather than hand-edited.
  final bool generated;

  bool get createsFile => beforeSha256 == null;

  Map<String, Object?> toJson() => {
        'path': path,
        'kind': kind.name,
        'summary': summary,
        'beforeSha256': beforeSha256,
        'afterSha256': afterSha256,
        'generated': generated,
        'hunks': [for (final h in hunks) h.toJson()],
        'diff': diff,
      };
}

/// An action the user must do by hand (e.g. switch the global Flutter SDK).
@immutable
final class ManualStep {
  const ManualStep({required this.title, required this.command});

  factory ManualStep.fromJson(JsonReader json) => ManualStep(
        title: json.string('title'),
        command: json.optionalString('command'),
      );

  final String title;
  final String? command;

  Map<String, Object?> toJson() => {'title': title, 'command': command};
}
