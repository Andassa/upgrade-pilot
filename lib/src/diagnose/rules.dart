import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';

/// What the resolver can do automatically for a diagnosed problem.
enum FixAction {
  setConstraint,
  upgradeDependency,
  widenSdkConstraint,
  gradleForJdk,
  bumpAgp,
  bumpGradle,
  bumpKotlin,
  bumpAgpForCompileSdk,
  disableBuiltInKotlin,
  disableNewDsl,
  setMinSdk,
  setCompileSdk,
  normalizeGradleDistribution,
  alignJvmTarget,
  setIosDeploymentTarget,

  /// Needs a human: environment problem or code migration.
  none,
}

final class RulesException implements Exception {
  RulesException(this.message);

  final String message;

  @override
  String toString() => 'Diagnostic rules: $message';
}

/// A declarative diagnostic rule loaded from `data/rules.json`.
@immutable
final class DiagnosticRule {
  const DiagnosticRule({
    required this.id,
    required this.title,
    required this.category,
    required this.steps,
    required this.patterns,
    required this.cause,
    required this.fix,
    required this.action,
    required this.confidence,
    required this.docsUrl,
    required this.source,
    required this.patternFrom,
    required this.retrievedAt,
  });

  factory DiagnosticRule.fromJson(JsonReader json) {
    final id = json.string('id');
    if (!idPattern.hasMatch(id)) throw RulesException('invalid id "$id"');
    final action = json.object('action').string('kind');
    final confidence = json.string('confidence');
    final patterns = json.strings('patterns');
    if (patterns.isEmpty) throw RulesException('$id has no pattern');
    return DiagnosticRule(
      id: id,
      title: json.string('title'),
      category: json.string('category'),
      steps: json.strings('steps'),
      patterns: [for (final raw in patterns) RegExp(raw, multiLine: true)],
      cause: json.string('cause'),
      fix: json.string('fix'),
      action: FixAction.values.asNameMap()[action] ??
          (throw RulesException('$id: unknown action "$action"')),
      confidence: Confidence.values.asNameMap()[confidence] ??
          (throw RulesException('$id: unknown confidence "$confidence"')),
      docsUrl: json.string('docsUrl'),
      source: json.string('source'),
      patternFrom: json.string('patternFrom'),
      retrievedAt: json.string('retrievedAt'),
    );
  }

  static final idPattern = RegExp(r'^UP-[A-Z]{3,4}-\d{4}$');

  final String id;
  final String title;
  final String category;

  /// Steps this rule applies to; `*` for all.
  final List<String> steps;
  final List<RegExp> patterns;

  /// Templates; `{name}` is replaced by the named capture group.
  final String cause;
  final String fix;
  final FixAction action;
  final Confidence confidence;
  final String docsUrl;
  final String source;
  final String patternFrom;
  final String retrievedAt;

  bool appliesTo(String step) => steps.contains('*') || steps.contains(step);
}

/// The ordered rule set. Order is priority.
@immutable
final class RuleSet {
  const RuleSet(this.rulesVersion, this.rules);

  factory RuleSet.parse(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, Object?>) {
        throw RulesException('expected a JSON object');
      }
      final json = JsonReader(decoded);
      if (json['schemaVersion'] != 1) {
        throw RulesException('unsupported schemaVersion');
      }
      final rules = json
          .objects('rules')
          .map(DiagnosticRule.fromJson)
          .toList(growable: false);
      final ids = <String>{};
      for (final rule in rules) {
        if (!ids.add(rule.id)) throw RulesException('duplicate id ${rule.id}');
      }
      return RuleSet(json.string('rulesVersion'), rules);
    } on FormatException catch (e) {
      throw RulesException('invalid data: ${e.message}');
    }
  }

  final String rulesVersion;
  final List<DiagnosticRule> rules;

  DiagnosticRule? byId(String id) {
    for (final rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }
}
