// Weekly check of the knowledge base: every cited URL still answers, and
// the latest stable Flutter minor is covered.
//
// Usage: dart run tool/kb_freshness.dart
import 'dart:convert';
import 'dart:io';

Future<int> _status(HttpClient client, Uri uri) async {
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } on IOException {
    return -1;
  }
}

Future<void> main() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var problems = 0;
  final urls = <String>{};
  for (final path in ['data/kb.json', 'data/rules.json']) {
    urls.addAll(
      RegExp(r'https://[^\s"]+')
          .allMatches(File(path).readAsStringSync())
          .map((m) => m.group(0)!)
          .where((u) => !u.contains('(') && !u.contains('[')),
    );
  }
  for (final url in urls.toList()..sort()) {
    final status = await _status(client, Uri.parse(url));
    if (status != 200) {
      stdout.writeln('unreachable ($status): $url');
      problems++;
    }
  }

  final releases = await client
      .getUrl(
        Uri.parse(
          'https://storage.googleapis.com/flutter_infra_release/releases/'
          'releases_linux.json',
        ),
      )
      .then((r) => r.close())
      .then((r) => r.transform(utf8.decoder).join());
  final json = jsonDecode(releases) as Map<String, Object?>;
  final stableHash =
      (json['current_release']! as Map<String, Object?>)['stable'];
  final stable = (json['releases']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .firstWhere((r) => r['hash'] == stableHash);
  final version = '${stable['version']}';
  final minor = version.split('.').take(2).join('.');
  final kb = jsonDecode(File('data/kb.json').readAsStringSync())
      as Map<String, Object?>;
  final covered = (kb['flutter']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .any((e) => e['minor'] == minor);
  if (!covered) {
    stdout.writeln(
      'Flutter $version is the current stable; add a "$minor" entry to '
      'data/kb.json (sources: flutter_tools gradle_utils.dart and '
      'DependencyVersionChecker.kt at tag $version).',
    );
    problems++;
  }
  client.close();
  stdout.writeln('${urls.length} URLs checked, current stable $version.');
  exit(problems == 0 ? 0 : 1);
}
