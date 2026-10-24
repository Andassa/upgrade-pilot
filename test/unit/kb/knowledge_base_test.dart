import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/diagnose/embedded_rules.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/kb/embedded_kb.dart';
import 'package:upgrade_pilot/src/kb/kb_loader.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';

import '../../support/fakes.dart';

void main() {
  final kb = KbLoader.embedded();

  test('embedded copies match data/ and their checksums', () {
    final kbFile = File('data/kb.json').readAsStringSync();
    final rulesFile = File('data/rules.json').readAsStringSync();
    expect(embeddedKb, kbFile, reason: 'run `make data`');
    expect(embeddedRules, rulesFile, reason: 'run `make data`');
    expect(sha256Hex(embeddedKb), embeddedKbSha256);
    expect(sha256Hex(embeddedRules), embeddedRulesSha256);
    expect(
      File('data/kb.json.sha256').readAsStringSync().trim(),
      embeddedKbSha256,
      reason: 'kb update downloads this checksum',
    );
  });

  test('every Flutter entry and table cites a source and a date', () {
    final raw = jsonDecode(embeddedKb) as Map<String, Object?>;
    final date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    for (final entry in kb.flutter) {
      expect(entry.sources, isNotEmpty, reason: entry.minor);
      for (final source in entry.sources) {
        expect(source, startsWith('https://'));
      }
      expect(entry.retrievedAt, matches(date));
    }
    for (final key in ['agpMinGradle', 'javaGradle', 'compileSdkMinAgp']) {
      final table = raw[key]! as Map<String, Object?>;
      expect(table['source'], startsWith('https://'), reason: key);
      expect(table['retrievedAt'], matches(date), reason: key);
    }
  });

  test('lookups', () {
    final f344 = kb.forFlutter(Version(3, 44, 8))!;
    expect(f344.templateAgp, Version(9, 0, 1));
    expect(f344.agp.error, Version(8, 6, 0));
    expect(f344.agp.warn, Version(8, 11, 1));
    expect(f344.templateGradleProperties['android.builtInKotlin'], 'false');
    expect(f344.minSdk, 24);
    expect(
      kb.forFlutter(Version(3, 41, 0))!.templateAgp,
      isNull,
      reason: 'unknown',
    );
    expect(kb.forFlutter(Version(2, 10, 0)), isNull);

    expect(kb.minGradleForAgp(Version(8, 7, 3)), Version(8, 9, 0));
    expect(kb.minGradleForAgp(Version(9, 0, 1)), Version(9, 1, 0));
    expect(kb.minGradleForAgp(Version(10, 0, 0)), isNull);

    final java25 = kb.gradleRangeForJava(25)!;
    expect(java25.min, Version(9, 1, 0));
    expect(java25.maxExclusive, isNull);
    expect(kb.gradleRangeForJava(11)!.maxExclusive, Version(8, 15, 0));
    expect(kb.gradleRangeForJava(99), isNull);

    expect(kb.minAgpForCompileSdk(35), Version(8, 6, 0));
    expect(kb.minAgpForCompileSdk(20), isNull);
  });

  group('parse errors', () {
    test('invalid JSON and structure', () {
      expect(
        () => KnowledgeBase.parse('{', sha256: ''),
        throwsA(isA<KnowledgeBaseException>()),
      );
      expect(
        () => KnowledgeBase.parse('[]', sha256: ''),
        throwsA(isA<KnowledgeBaseException>()),
      );
      expect(
        () => KnowledgeBase.parse('{"schemaVersion": 2}', sha256: ''),
        throwsA(isA<KnowledgeBaseException>()),
      );
      expect(
        () => KnowledgeBase.parse(
          '{"schemaVersion": 1, "kbVersion": 3}',
          sha256: '',
        ),
        throwsA(
          isA<KnowledgeBaseException>().having(
            (e) => e.toString(),
            'message',
            contains('unexpected structure'),
          ),
        ),
      );
    });
  });

  group('KbLoader', () {
    late MemoryFileSystem fs;
    late KbLoader loader;
    setUp(() {
      fs = MemoryFileSystem();
      loader = KbLoader(fs, '/cache');
    });

    String newer() {
      final json = jsonDecode(embeddedKb) as Map<String, Object?>;
      json['kbVersion'] = '2099.01.01';
      return jsonEncode(json);
    }

    test('uses the embedded KB without a cached copy', () async {
      expect((await loader.load()).kbVersion, kb.kbVersion);
    });

    test('uses a newer cached KB with a valid checksum', () async {
      final content = newer();
      fs
        ..addFile(loader.cachedPath, content)
        ..addFile(
          loader.cachedChecksumPath,
          '${sha256Hex(content)}  kb.json\n',
        );
      expect((await loader.load()).kbVersion, '2099.01.01');
    });

    test('ignores a cached KB with a wrong checksum', () async {
      fs
        ..addFile(loader.cachedPath, newer())
        ..addFile(loader.cachedChecksumPath, 'deadbeef');
      expect((await loader.load()).kbVersion, kb.kbVersion);
    });

    test('ignores an older or malformed cached KB', () async {
      const broken = '{"schemaVersion": 1}';
      fs
        ..addFile(loader.cachedPath, broken)
        ..addFile(loader.cachedChecksumPath, sha256Hex(broken));
      expect((await loader.load()).kbVersion, kb.kbVersion);
      fs
        ..addFile(loader.cachedPath, embeddedKb)
        ..addFile(loader.cachedChecksumPath, sha256Hex(embeddedKb));
      expect((await loader.load()).kbVersion, kb.kbVersion);
    });
  });
}
