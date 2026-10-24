import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/application/git.dart';
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/patch/diff.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Why `apply` refused to run. Each value maps to a documented message.
enum ApplyRefusal {
  noPlan,
  blockedPlan,
  emptyPlan,
  projectChanged,
  dirtyWorktree,
  fileConflict,
  noBackup,
  notConfirmed,
}

final class ApplyRefusedException implements Exception {
  ApplyRefusedException(this.reason, {this.detail});

  final ApplyRefusal reason;
  final String? detail;

  @override
  String toString() => '${reason.name}${detail == null ? '' : ': $detail'}';
}

@immutable
final class ApplyResult {
  const ApplyResult({
    required this.plan,
    required this.applied,
    required this.backupDirectory,
  });

  final Plan plan;
  final List<Change> applied;
  final String backupDirectory;
}

@immutable
final class RevertResult {
  const RevertResult({required this.restored, required this.backupDirectory});

  final List<String> restored;
  final String backupDirectory;
}

/// `apply`: writes the last verified plan into the project, after a
/// backup. `revert` restores that backup.
final class ApplyUseCase {
  ApplyUseCase({
    required FileSystem fs,
    required Host host,
    required Clock clock,
    required PlanStore store,
    required GitClient git,
  })  : _fs = fs,
        _host = host,
        _clock = clock,
        _store = store,
        _git = git;

  final FileSystem _fs;
  final Host _host;
  final Clock _clock;
  final PlanStore _store;
  final GitClient _git;

  String _abs(String root, String relative) =>
      p.joinAll([root, ...relative.split('/')]);

  /// Kept outside `plans/` so that `clean` never deletes a backup.
  Future<String> _backups(String root) async => p.join(
        _host.cacheDirectory,
        'backups',
        p.basename(await _store.directoryFor(root)),
      );

  /// Loads the plan and checks every precondition without writing.
  /// Returns the plan and the new content of each changed file.
  Future<(Plan, Map<String, (String?, String)>)> check(
    String projectPath, {
    bool force = false,
  }) async {
    final root = await _fs.canonicalize(projectPath);
    final plan = await _store.load(root);
    if (plan == null) throw ApplyRefusedException(ApplyRefusal.noPlan);
    if (plan.verdict == Verdict.blocked) {
      throw ApplyRefusedException(ApplyRefusal.blockedPlan);
    }
    if (plan.changes.isEmpty) {
      throw ApplyRefusedException(ApplyRefusal.emptyPlan);
    }
    if (await projectFingerprint(_fs, root) != plan.project.fingerprint) {
      throw ApplyRefusedException(ApplyRefusal.projectChanged);
    }
    if (!force && await _git.isRepository(root) && !await _git.isClean(root)) {
      throw ApplyRefusedException(ApplyRefusal.dirtyWorktree);
    }
    final contents = <String, (String?, String)>{};
    for (final change in plan.changes) {
      final current = await _fs.readString(_abs(root, change.path));
      final matches = change.createsFile
          ? current == null
          : current != null && sha256Hex(current) == change.beforeSha256;
      if (!matches) {
        throw ApplyRefusedException(
          ApplyRefusal.fileConflict,
          detail: change.path,
        );
      }
      final String after;
      try {
        after = applyHunks(current, change.hunks);
      } on FormatException {
        throw ApplyRefusedException(
          ApplyRefusal.fileConflict,
          detail: change.path,
        );
      }
      if (sha256Hex(after) != change.afterSha256) {
        throw ApplyRefusedException(
          ApplyRefusal.fileConflict,
          detail: change.path,
        );
      }
      contents[change.path] = (current, after);
    }
    return (plan, contents);
  }

  Future<ApplyResult> apply(String projectPath, {bool force = false}) async {
    final root = await _fs.canonicalize(projectPath);
    final (plan, contents) = await check(root, force: force);
    final stamp = _clock().toUtc().toIso8601String().replaceAll(':', '-');
    final backup = p.join(await _backups(root), stamp);
    await _fs.writeString(
      p.join(backup, 'manifest.json'),
      const JsonEncoder.withIndent('  ').convert({
        'createdAt': _clock().toUtc().toIso8601String(),
        'planCreatedAt': plan.createdAt.toUtc().toIso8601String(),
        'target': plan.target.toJson(),
        'files': [
          for (final MapEntry(key: path, value: (before, after))
              in contents.entries)
            {
              'path': path,
              'created': before == null,
              'afterSha256': sha256Hex(after),
              'reverse': [
                for (final h in computeHunks(after, before ?? '')) h.toJson(),
              ],
            },
        ],
      }),
    );
    for (final MapEntry(key: path, value: (_, after)) in contents.entries) {
      await _fs.writeString(_abs(root, path), after);
    }
    return ApplyResult(
      plan: plan,
      applied: plan.changes,
      backupDirectory: backup,
    );
  }

  /// Restores the most recent backup. Files edited after `apply` are
  /// only overwritten with [force].
  Future<RevertResult> revert(String projectPath, {bool force = false}) async {
    final root = await _fs.canonicalize(projectPath);
    final dir = await _backups(root);
    final backups = [
      for (final e in await _fs.list(dir))
        if (e.type == EntryType.directory && !e.path.endsWith('.reverted'))
          e.path,
    ]..sort();
    if (backups.isEmpty) throw ApplyRefusedException(ApplyRefusal.noBackup);
    final latest = backups.last;
    final manifest = await _fs.readString(p.join(latest, 'manifest.json'));
    final List<JsonReader> files;
    try {
      final decoded = jsonDecode(manifest ?? '');
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('expected an object');
      }
      files = JsonReader(decoded).objects('files');
    } on FormatException {
      throw ApplyRefusedException(ApplyRefusal.noBackup, detail: 'corrupted');
    }
    final restored = <String, String?>{};
    for (final file in files) {
      final path = file.string('path');
      final current = await _fs.readString(_abs(root, path));
      if (current == null ||
          (!force && sha256Hex(current) != file.string('afterSha256'))) {
        throw ApplyRefusedException(ApplyRefusal.fileConflict, detail: path);
      }
      if (file.boolean('created')) {
        restored[path] = null;
        continue;
      }
      try {
        restored[path] = applyHunks(
          current,
          file.objects('reverse').map(Hunk.fromJson).toList(),
        );
      } on FormatException {
        // Backups keep changed lines only; they cannot be replayed on a
        // file whose structure changed since `apply`.
        throw ApplyRefusedException(ApplyRefusal.fileConflict, detail: path);
      }
    }
    for (final MapEntry(key: path, value: content) in restored.entries) {
      if (content == null) {
        await _fs.deleteRecursive(_abs(root, path));
      } else {
        await _fs.writeString(_abs(root, path), content);
      }
    }
    await _fs.rename(latest, '$latest.reverted');
    return RevertResult(
      restored: restored.keys.toList(),
      backupDirectory: latest,
    );
  }
}
