import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/diagnose/embedded_rules.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';

import 'samples.dart';

void main() {
  final rules = RuleSet.parse(embeddedRules);
  final diagnoser = Diagnoser(
    rules,
    redactor: Redactor(homeDirectory: '/home/dev'),
  );

  test('every rule is well formed, sourced and has a sample', () {
    final date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    for (final rule in rules.rules) {
      expect(rule.docsUrl, startsWith('https://'), reason: rule.id);
      expect(rule.source, startsWith('https://'), reason: rule.id);
      expect(rule.patternFrom, isNotEmpty, reason: rule.id);
      expect(rule.retrievedAt, matches(date), reason: rule.id);
      expect(ruleSamples, contains(rule.id), reason: 'sample for ${rule.id}');
    }
    expect(ruleSamples.keys.toSet(), rules.rules.map((r) => r.id).toSet());
  });

  for (final MapEntry(key: id, value: (step, output)) in ruleSamples.entries) {
    test('$id matches its sample first', () {
      final results = diagnoser.diagnose(step: step, output: output);
      expect(results.first.finding.id, id);
      final finding = results.first.finding;
      expect(
        finding.cause,
        isNot(contains('{')),
        reason: 'placeholders filled',
      );
      expect(finding.fix, isNot(contains('{')));
      expect(finding.excerpt, isNotEmpty);
      expect(finding.step, step);
    });
  }

  test('captures drive the fix', () {
    final (step, output) = ruleSamples['UP-PUB-0002']!;
    final d = diagnoser.diagnose(step: step, output: output).first;
    expect(d.action, FixAction.setConstraint);
    expect(d.finding.captures, {'package': 'http', 'constraint': '^1.6.0'});
    expect(d.finding.fix, contains('^1.6.0'));
    expect(d.category, 'pub');
    expect(d.isEnvironment, isFalse);
  });

  test('environment rules are flagged', () {
    final (step, output) = ruleSamples['UP-ENV-0005']!;
    final d = diagnoser.diagnose(step: step, output: output).first;
    expect(d.isEnvironment, isTrue);
    expect(d.finding.cause, contains('~/Library/Android'));
    expect(d.finding.excerpt, isNot(contains('/home/dev')));
  });

  test('home paths are redacted in captures and excerpts', () {
    final (step, output) = ruleSamples['UP-AND-0014']!;
    final finding =
        diagnoser.diagnose(step: step, output: output).first.finding;
    expect(finding.captures['package'], 'flutter_old_plugin');
    expect(finding.excerpt, contains('~/.pub-cache'));
    expect(finding.excerpt, isNot(contains('/home/dev')));
  });

  test('rules only apply to their steps', () {
    final (_, output) = ruleSamples['UP-PUB-0001']!;
    final results = diagnoser.diagnose(step: 'build apk', output: output);
    expect(results.single.finding.id, Finding.unidentifiedId);
  });

  group('no rule matches', () {
    test('says so and keeps the "What went wrong" block', () {
      final results = diagnoser.diagnose(
        step: 'build apk',
        output: 'noise\n* What went wrong:\nSomething odd\n\n* Try:\n> x',
      );
      final f = results.single.finding;
      expect(f.identified, isFalse);
      expect(f.confidence, Confidence.low);
      expect(f.cause, contains('No diagnostic rule'));
      expect(f.excerpt, startsWith('* What went wrong:'));
      expect(results.single.action, FixAction.none);
    });

    test('falls back to error lines, then to the tail', () {
      final errors = diagnoser.diagnose(
        step: 'test',
        output: 'a\nb\nsome error here\nc',
      );
      expect(errors.single.finding.excerpt, 'some error here');
      final tail = diagnoser.diagnose(
        step: 'test',
        output: List.generate(30, (i) => 'line $i').join('\n'),
      );
      expect(tail.single.finding.excerpt.split('\n'), hasLength(14));
      expect(tail.single.finding.excerpt, endsWith('line 29'));
    });
  });

  test('excerpts are limited and trimmed', () {
    const failure =
        'Because a depends on b 1.0.0 which requires SDK version >=2.0.0 '
        '<3.0.0, version solving failed.';
    final output = [
      '',
      failure,
      for (var i = 0; i < 30; i++) 'extra $i',
    ].join('\r\n');
    final f = diagnoser.diagnose(step: 'pub get', output: output).first.finding;
    expect(f.excerpt.split('\n').length, lessThanOrEqualTo(14));
    expect(f.excerpt, isNot(contains('\r')));
  });

  group('rule set validation', () {
    Map<String, Object?> rule([Map<String, Object?> overrides = const {}]) => {
          'id': 'UP-TST-0001',
          'title': 't',
          'category': 'pub',
          'steps': ['*'],
          'patterns': ['x'],
          'cause': 'c',
          'fix': 'f',
          'action': {'kind': 'none'},
          'confidence': 'high',
          'docsUrl': 'https://x',
          'source': 'https://x',
          'patternFrom': 'p',
          'retrievedAt': '2026-10-24',
          ...overrides,
        };
    String set(List<Object?> rules) => jsonEncode({
          'schemaVersion': 1,
          'rulesVersion': 'v',
          'rules': rules,
        });

    test('accepts a valid set', () {
      final parsed = RuleSet.parse(set([rule()]));
      expect(parsed.byId('UP-TST-0001')!.appliesTo('anything'), isTrue);
      expect(parsed.byId('UP-NOPE-0000'), isNull);
    });

    test('rejects invalid sets', () {
      for (final bad in [
        '{',
        '[]',
        jsonEncode({'schemaVersion': 2}),
        set([
          rule({'id': 'bad'}),
        ]),
        set([rule(), rule()]),
        set([
          rule({
            'action': {'kind': 'explode'},
          }),
        ]),
        set([
          rule({'confidence': 'certain'}),
        ]),
        set([
          rule({'patterns': <String>[]}),
        ]),
        set([
          rule({'title': 3}),
        ]),
      ]) {
        expect(
          () => RuleSet.parse(bad),
          throwsA(isA<RulesException>()),
          reason: bad,
        );
      }
      expect(RulesException('x').toString(), 'Diagnostic rules: x');
    });
  });
}
