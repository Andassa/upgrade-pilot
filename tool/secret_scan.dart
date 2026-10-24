// Scans git-tracked files for credentials. Used by `make security` when
// gitleaks is not installed; CI runs gitleaks as well.
import 'dart:io';

final _patterns = <String, RegExp>{
  'private key': RegExp('-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  'GitHub token': RegExp(r'\bgh[pousr]_[A-Za-z0-9]{36,}\b'),
  'GitHub fine-grained token': RegExp(r'\bgithub_pat_[A-Za-z0-9_]{60,}\b'),
  'AWS access key': RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  'Google API key': RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
  'Slack token': RegExp(r'\bxox[abprs]-[0-9]{10,}-[A-Za-z0-9-]{10,}'),
  'pub.dev credentials': RegExp(r'"accessToken"\s*:\s*"ya29\.'),
};

/// Test files that deliberately contain fake secrets to prove redaction.
const _allowed = {
  'test/security/secret_leak_test.dart',
  'test/support/scenario.dart',
};

void main() {
  final listed = Process.runSync('git', ['ls-files', '-z']);
  if (listed.exitCode != 0) {
    stderr.writeln('secret_scan: not a git repository');
    exit(1);
  }
  final files = '${listed.stdout}'.split('\u0000').where((f) => f.isNotEmpty);
  var findings = 0;
  for (final path in files) {
    if (_allowed.contains(path)) continue;
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > 2 * 1024 * 1024) continue;
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final MapEntry(key: kind, value: pattern) in _patterns.entries) {
      for (final match in pattern.allMatches(content)) {
        final line = '\n'.allMatches(content.substring(0, match.start)).length;
        stdout.writeln('$path:${line + 1}: possible $kind');
        findings++;
      }
    }
  }
  if (findings > 0) {
    stderr.writeln('secret_scan: $findings possible secret(s) found');
    exit(1);
  }
  stdout.writeln('secret_scan: no secret found in ${files.length} files');
}
