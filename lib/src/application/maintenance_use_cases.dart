import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/kb/kb_loader.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// What `explain` found for an identifier.
@immutable
final class Explanation {
  const Explanation({required this.id, this.finding, this.rule});

  final String id;

  /// The finding of the last plan, with its real log excerpt.
  final Finding? finding;
  final DiagnosticRule? rule;
}

final class UnknownFindingException implements Exception {
  UnknownFindingException(this.id);

  final String id;
}

/// `explain <id>`.
final class ExplainUseCase {
  ExplainUseCase(this._store, this._rules);

  final PlanStore _store;
  final RuleSet _rules;

  Future<Explanation> explain(String projectPath, String rawId) async {
    final id = rawId.trim().toUpperCase();
    Finding? finding;
    try {
      finding = (await _store.load(projectPath))?.finding(id);
    } on PlanStoreException {
      finding = null;
    }
    final rule = _rules.byId(id);
    if (finding == null && rule == null) throw UnknownFindingException(id);
    return Explanation(id: id, finding: finding, rule: rule);
  }
}

@immutable
final class KbUpdateResult {
  const KbUpdateResult({
    required this.previous,
    required this.current,
    required this.updated,
  });

  final String previous;
  final String current;
  final bool updated;
}

/// `kb update`: downloads the published KB, verifies its SHA-256 and
/// structure, and installs it only when newer.
final class KbUpdateUseCase {
  KbUpdateUseCase({
    required HttpPort http,
    required FileSystem fs,
    required KbLoader loader,
    this.baseUrl =
        'https://raw.githubusercontent.com/Andassa/upgrade-pilot/main/data/',
  })  : _http = http,
        _fs = fs,
        _loader = loader;

  final HttpPort _http;
  final FileSystem _fs;
  final KbLoader _loader;
  final String baseUrl;

  Future<KbUpdateResult> update() async {
    final current = await _loader.load();
    final body = await _http.get(Uri.parse('${baseUrl}kb.json'));
    final checksum = await _http.get(Uri.parse('${baseUrl}kb.json.sha256'));
    if (!body.ok || !checksum.ok) {
      final status = body.ok ? checksum.statusCode : body.statusCode;
      throw NetworkException('Knowledge base download failed (HTTP $status)');
    }
    final content = utf8.decode(body.body);
    final expected =
        utf8.decode(checksum.body).trim().split(RegExp(r'\s+')).first;
    final actual = sha256Hex(content);
    if (actual != expected) {
      throw KnowledgeBaseException(
        'checksum mismatch: expected $expected, got $actual',
      );
    }
    final downloaded = KnowledgeBase.parse(content, sha256: actual);
    if (downloaded.kbVersion.compareTo(current.kbVersion) <= 0) {
      return KbUpdateResult(
        previous: current.kbVersion,
        current: current.kbVersion,
        updated: false,
      );
    }
    await _fs.writeString(_loader.cachedPath, content);
    await _fs.writeString(_loader.cachedChecksumPath, '$actual\n');
    return KbUpdateResult(
      previous: current.kbVersion,
      current: downloaded.kbVersion,
      updated: true,
    );
  }
}

/// `clean`: removes caches and leftover sandboxes.
final class CleanUseCase {
  CleanUseCase(this._fs, this._host);

  final FileSystem _fs;
  final Host _host;

  /// Returns the deleted paths.
  Future<List<String>> clean({bool keepSdks = false}) async {
    final removed = <String>[];
    for (final name in [
      'downloads',
      'releases',
      'pub',
      'plans',
      if (!keepSdks) 'sdks',
    ]) {
      final path = p.join(_host.cacheDirectory, name);
      if (await _fs.exists(path)) {
        await _fs.deleteRecursive(path);
        removed.add(path);
      }
    }
    for (final entry in await _fs.list(_host.temporaryDirectory)) {
      if (entry.type == EntryType.directory &&
          p.basename(entry.path).startsWith('upgrade-pilot-')) {
        await _fs.deleteRecursive(entry.path);
        removed.add(entry.path);
      }
    }
    return removed;
  }
}
