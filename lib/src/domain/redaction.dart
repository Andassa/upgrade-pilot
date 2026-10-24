/// Removes secrets and personal paths from text that may end up in logs,
/// reports or caches.
final class Redactor {
  Redactor({String? homeDirectory, Iterable<String> extraPaths = const []})
      : _paths = [
          ...extraPaths.where((p) => p.length > 1),
          if (homeDirectory != null && homeDirectory.length > 1) homeDirectory,
        ];

  final List<String> _paths;

  static const placeholder = '<redacted>';

  static final _rules = <(RegExp, String Function(Match))>[
    (
      RegExp(
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        r'[\s\S]*?'
        '-----END [A-Z ]*PRIVATE KEY-----',
      ),
      (_) => '<redacted private key>',
    ),
    (
      RegExp(
        r'''(?<key>(?:store|key)?_?(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|auth)[A-Za-z_]*)(?<sep>\s*[:=]\s*["']?)(?<value>(?:(?:Bearer|Basic|Token)\s+)?[^\s"',;]+)''',
        caseSensitive: false,
      ),
      (m) {
        final match = m as RegExpMatch;
        final key = match.namedGroup('key');
        return '$key${match.namedGroup('sep')}$placeholder';
      },
    ),
    (
      RegExp(r'(?<scheme>https?://)[^/\s:@]+:[^/\s@]+@'),
      (m) => '${(m as RegExpMatch).namedGroup('scheme')}$placeholder@',
    ),
    (
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{8,}'),
      (_) => 'Bearer $placeholder'
    ),
    (RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'), (_) => placeholder),
    (RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}'), (_) => placeholder),
    (RegExp(r'\bAKIA[0-9A-Z]{16}\b'), (_) => placeholder),
    (RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'), (_) => placeholder),
    (RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}'), (_) => placeholder),
    (RegExp(r'\bsk-[A-Za-z0-9]{20,}'), (_) => placeholder),
    (
      RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
      (_) => placeholder,
    ),
  ];

  String redact(String text) {
    var result = text;
    for (final path in _paths) {
      result = result.replaceAll(path, '~');
    }
    for (final (pattern, replace) in _rules) {
      result = result.replaceAllMapped(pattern, replace);
    }
    return result;
  }
}
