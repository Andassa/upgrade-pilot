import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/kb/embedded_kb.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';

/// Loads the knowledge base: the copy embedded in the binary, or a newer
/// copy installed by `kb update` once its checksum is verified.
final class KbLoader {
  KbLoader(this._fs, this._cacheDirectory);

  final FileSystem _fs;
  final String _cacheDirectory;

  String get cachedPath => p.join(_cacheDirectory, 'kb', 'kb.json');
  String get cachedChecksumPath => '$cachedPath.sha256';

  /// The embedded KB. Its checksum is verified at load time.
  static KnowledgeBase embedded() {
    final actual = sha256Hex(embeddedKb);
    if (actual != embeddedKbSha256) {
      throw KnowledgeBaseException('embedded data failed its checksum');
    }
    return KnowledgeBase.parse(embeddedKb, sha256: actual);
  }

  /// The most recent valid KB. A cached copy with a bad checksum or an
  /// older version is ignored.
  Future<KnowledgeBase> load() async {
    final base = embedded();
    final cached = await _fs.readString(cachedPath);
    final checksum = await _fs.readString(cachedChecksumPath);
    if (cached == null || checksum == null) return base;
    final actual = sha256Hex(cached);
    if (actual != checksum.trim().split(RegExp(r'\s+')).first) return base;
    try {
      final candidate = KnowledgeBase.parse(cached, sha256: actual);
      return candidate.kbVersion.compareTo(base.kbVersion) > 0
          ? candidate
          : base;
    } on KnowledgeBaseException {
      return base;
    }
  }
}
