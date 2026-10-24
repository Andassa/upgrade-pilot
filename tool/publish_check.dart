// Runs `dart pub publish --dry-run` and fails on any problem except the
// missing CHANGELOG.md: the repository only keeps README.md as Markdown.
import 'dart:io';

void main() {
  const arguments = ['pub', 'publish', '--dry-run'];
  final result = Process.runSync(
    'dart',
    arguments,
    runInShell: Platform.isWindows,
  );
  final output = '${result.stdout}${result.stderr}';
  stdout.write(output);
  if (result.exitCode == 0) return;
  final warnings = RegExp(r'Package has (\d+) warnings?\.').firstMatch(output);
  final onlyChangelog = warnings != null &&
      warnings.group(1) == '1' &&
      output.contains('Please add a `CHANGELOG.md`') &&
      !output.contains('Package validation found the following error');
  if (onlyChangelog) {
    stdout.writeln('publish_check: only the CHANGELOG.md warning, accepted.');
    return;
  }
  exit(result.exitCode);
}
