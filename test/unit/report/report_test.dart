import 'dart:convert';

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/report/html_report.dart';
import 'package:upgrade_pilot/src/report/json_report.dart';
import 'package:upgrade_pilot/src/report/markdown_report.dart';
import 'package:upgrade_pilot/src/report/report_text.dart';

import '../../support/builders.dart';

void main() {
  final verified = samplePlan();
  final blocked = samplePlan(verdict: Verdict.blocked);

  group('JSON', () {
    test('versioned, without edit hunks, and round-trippable plan data', () {
      final json =
          jsonDecode(renderJsonReport(verified)) as Map<String, Object?>;
      expect(json['reportSchemaVersion'], reportSchemaVersion);
      expect(json['schemaVersion'], Plan.schemaVersion);
      final changes = json['changes']! as List<Object?>;
      expect(
        (changes.first! as Map<String, Object?>).containsKey('hunks'),
        isFalse,
      );
      expect((changes.first! as Map<String, Object?>)['diff'], contains('+++'));
      final blockedJson = (planReportJson(blocked)['blocked']! as List<Object?>)
          .single! as Map<String, Object?>;
      expect(blockedJson['suggestionVerified'], isFalse);
    });

    test('plan JSON round trip', () {
      final copy = Plan.fromJson(
        jsonDecode(jsonEncode(verified.toJson())) as Map<String, Object?>,
      );
      expect(jsonEncode(copy.toJson()), jsonEncode(verified.toJson()));
      expect(copy.finalEvidence.map((e) => e.attempt).toSet(), {2});
      expect(copy.finding('UP-PUB-0001'), isNotNull);
      expect(copy.finding('nope'), isNull);
      expect(verified.isApplicable, isTrue);
      expect(blocked.isApplicable, isFalse);
      expect(
        () => Plan.fromJson(const {'schemaVersion': 2}),
        throwsFormatException,
      );
    });
  });

  group('Markdown', () {
    test('verified plan for a pull request', () {
      final md = renderMarkdownReport(verified);
      expect(
        md,
        startsWith(
          '## upgrade-pilot · legacy_app → Flutter 3.24.5 → 3.44.9 (stable, '
          'Dart 3.12.2)',
        ),
      );
      expect(md, contains('> **✔ Verified plan**'));
      expect(md, contains('Android build: ✔ passed'));
      expect(md, contains('iOS build: ─ not verified'));
      expect(
        md,
        contains('<details><summary><code>android/settings.gradle</code>'),
      );
      expect(md, contains('```diff'));
      expect(md, contains('| `http` | ^0.12.2 → ^1.6.0 | 0.12.2 → 1.6.0 |'));
      expect(md, contains('### Not verified'));
      expect(md, contains('### Limits'));
      expect(md, contains('commit `0123456`'));
      expect(md, contains('flutter upgrade'));
    });

    test('blocked plan says changes are not verified', () {
      final md = renderMarkdownReport(blocked);
      expect(md, contains('✖ Plan blocked'));
      expect(
        md,
        contains(
          '_Changes of the last attempt. They did not pass verification._',
        ),
      );
      expect(md, contains('Suggestion (not verified): other_dialog'));
      expect(md, contains('#### `UP-PUB-0001`'));
    });

    test('fences adapt to content containing backticks', () {
      final md = renderMarkdownReport(
        Plan.fromJson({
          ...verified.toJson(),
          'findings': [
            {...verified.findings.first.toJson(), 'excerpt': 'a ``` b'},
          ],
        }),
      );
      expect(md, contains('````text'));
    });
  });

  group('HTML', () {
    final html = renderHtmlReport(verified);

    test('self-contained and accessible', () {
      expect(html, startsWith('<!doctype html>\n<html lang="en">'));
      expect(html, contains('<meta name="viewport"'));
      expect(html, contains("default-src 'none'"));
      expect(html, contains('prefers-color-scheme:dark'));
      expect(html, contains('class="skip-link"'));
      expect(html, contains('<th scope="row">'));
      expect(html, isNot(contains('<script')));
      expect(html, isNot(contains('src="http')));
      expect(html, isNot(contains('<link')));
      expect(html, contains('aria-hidden="true"'));
    });

    test('escapes content', () {
      final hostile = Plan.fromJson({
        ...verified.toJson(),
        'project': {
          ...verified.project.toJson(),
          'name': '<script>alert(1)</script>',
        },
      });
      final out = renderHtmlReport(hostile);
      expect(out, isNot(contains('<script>alert')));
      expect(out, contains('&lt;script&gt;'));
    });

    test('blocked plans show findings and suggestions', () {
      final out = renderHtmlReport(blocked);
      expect(out, contains('class="fail"'));
      expect(out, contains('Suggestion (not verified)'));
      expect(out, contains('<pre tabindex="0"><code>'));
      expect(out, contains('<span class="add">'));
    });
  });

  test('report wording', () {
    expect(
      ReportText.duration(const Duration(minutes: 2, seconds: 7)),
      '2m 7s',
    );
    expect(
      ReportText.verdict(Verdict.verifiedWithWarnings),
      contains('warnings'),
    );
    expect(ReportText.verdictSymbol(Verdict.verifiedWithWarnings), '▲');
    final noFrom = Plan.fromJson({
      ...verified.toJson(),
      'project': {...verified.project.toJson(), 'flutterVersion': null},
    });
    expect(ReportText.fromTo(noFrom), '3.44.9 (stable, Dart 3.12.2)');
  });
}
