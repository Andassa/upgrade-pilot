import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/analysis/project_inspector.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Thrown when a stored plan cannot be read.
final class PlanStoreException implements Exception {
  PlanStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Stores plans outside the project, in the user cache, keyed by the
/// canonical project path.
final class PlanStore {
  PlanStore(this._fs, this._host);

  final FileSystem _fs;
  final Host _host;

  Future<String> directoryFor(String projectRoot) async {
    final canonical = await _fs.canonicalize(projectRoot);
    final id = sha256Hex(canonical).substring(0, 16);
    return p.join(_host.cacheDirectory, 'plans', id);
  }

  Future<String> planPath(String projectRoot) async =>
      p.join(await directoryFor(projectRoot), 'plan.json');

  Future<void> save(String projectRoot, Plan plan) async {
    final path = await planPath(projectRoot);
    await _fs.writeString(
      path,
      const JsonEncoder.withIndent('  ').convert(plan.toJson()),
    );
  }

  /// The last plan for [projectRoot], or `null` if there is none.
  Future<Plan?> load(String projectRoot) async {
    final content = await _fs.readString(await planPath(projectRoot));
    if (content == null) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('expected an object');
      }
      return Plan.fromJson(decoded);
    } on FormatException catch (e) {
      throw PlanStoreException('The stored plan is unreadable: ${e.message}');
    }
  }
}

/// SHA-256 over the files a plan may change. Any edit after `plan`
/// changes the fingerprint.
Future<String> projectFingerprint(FileSystem fs, String root) async {
  final buffer = StringBuffer();
  for (final relative in ProjectFiles.fingerprinted) {
    final content = await fs.readString(
      p.joinAll([root, ...relative.split('/')]),
    );
    buffer
      ..write(relative)
      ..write('\u0000')
      ..write(content == null ? '-' : sha256Hex(content))
      ..write('\n');
  }
  return sha256Hex(buffer.toString());
}
