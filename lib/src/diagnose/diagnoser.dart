import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/diagnose/embedded_rules.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';

/// A finding plus the automatic fix the resolver may try.
@immutable
final class Diagnosis {
  const Diagnosis(this.finding, this.action, {this.category = 'unknown'});

  final Finding finding;
  final FixAction action;

  /// Rule category: `pub`, `android`, `ios`, `dart`, `environment`.
  final String category;

  /// The machine, not the project, must change.
  bool get isEnvironment => category == 'environment';
}

/// Matches build output against [RuleSet]. Never invents a cause: when no
/// rule matches, it returns a single "unidentified" finding with the most
/// relevant log lines.
final class Diagnoser {
  Diagnoser(this.rules, {Redactor? redactor})
      : _redactor = redactor ?? Redactor();

  factory Diagnoser.embedded({Redactor? redactor}) =>
      Diagnoser(RuleSet.parse(embeddedRules), redactor: redactor);

  final RuleSet rules;
  final Redactor _redactor;

  static const _contextBefore = 2;
  static const _contextAfter = 6;
  static const _maxExcerptLines = 14;

  /// All matching rules in priority order, or one unidentified finding.
  List<Diagnosis> diagnose({required String step, required String output}) {
    final normalized = output.replaceAll('\r\n', '\n');
    final results = <Diagnosis>[];
    for (final rule in rules.rules) {
      if (!rule.appliesTo(step)) continue;
      for (final pattern in rule.patterns) {
        final match = pattern.firstMatch(normalized);
        if (match == null) continue;
        final captures = <String, String>{
          for (final name in match.groupNames)
            if (match.namedGroup(name) != null)
              name: _redactor.redact(match.namedGroup(name)!.trim()),
        };
        results.add(
          Diagnosis(
            Finding(
              id: rule.id,
              title: rule.title,
              cause: _fill(rule.cause, captures),
              fix: _fill(rule.fix, captures),
              confidence: rule.confidence,
              step: step,
              docsUrl: rule.docsUrl,
              excerpt: _excerptAround(normalized, match.start),
              captures: captures,
            ),
            rule.action,
            category: rule.category,
          ),
        );
        break;
      }
    }
    if (results.isNotEmpty) return results;
    return [
      Diagnosis(
        Finding(
          id: Finding.unidentifiedId,
          title: 'Cause not identified',
          cause: 'No diagnostic rule matches this output.',
          fix: 'Read the excerpt below. If the cause is a known upgrade '
              'problem, a rule can be contributed (see README).',
          confidence: Confidence.low,
          step: step,
          excerpt: _relevantLines(normalized),
        ),
        FixAction.none,
      ),
    ];
  }

  static String _fill(String template, Map<String, String> captures) =>
      template.replaceAllMapped(
        RegExp(r'\{([a-zA-Z]+)\}'),
        (m) => captures[m.group(1)] ?? m.group(0)!,
      );

  String _excerptAround(String output, int offset) {
    final lines = output.split('\n');
    var index = '\n'.allMatches(output.substring(0, offset)).length;
    if (index >= lines.length) index = lines.length - 1;
    final start = (index - _contextBefore).clamp(0, lines.length);
    final end = (index + _contextAfter + 1).clamp(0, lines.length);
    return _clean(lines.sublist(start, end));
  }

  static final _signal = RegExp(
    '(error|Error|ERROR|FAILURE|What went wrong|failed|Exception|Because )',
  );

  String _relevantLines(String output) {
    final lines = output.split('\n');
    final whatWentWrong = lines.lastIndexWhere(
      (l) => l.contains('What went wrong'),
    );
    if (whatWentWrong >= 0) {
      return _clean(
        lines.sublist(
          whatWentWrong,
          (whatWentWrong + _maxExcerptLines).clamp(0, lines.length),
        ),
      );
    }
    final signals = lines.where(_signal.hasMatch).toList();
    if (signals.isNotEmpty) {
      return _clean(
        signals.sublist((signals.length - _maxExcerptLines).clamp(0, 1 << 30)),
      );
    }
    return _clean(
      lines.sublist((lines.length - _maxExcerptLines).clamp(0, lines.length)),
    );
  }

  String _clean(List<String> lines) {
    final trimmed = lines.map((l) => l.trimRight()).toList();
    while (trimmed.isNotEmpty && trimmed.first.trim().isEmpty) {
      trimmed.removeAt(0);
    }
    while (trimmed.isNotEmpty && trimmed.last.trim().isEmpty) {
      trimmed.removeLast();
    }
    final limited = trimmed.length > _maxExcerptLines
        ? trimmed.sublist(0, _maxExcerptLines)
        : trimmed;
    return _redactor.redact(limited.join('\n'));
  }
}
