import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';

/// How sure the diagnoser is about a cause.
enum Confidence { high, medium, low }

/// A diagnosed problem, produced from real build output.
@immutable
final class Finding {
  const Finding({
    required this.id,
    required this.title,
    required this.cause,
    required this.fix,
    required this.confidence,
    required this.step,
    this.docsUrl,
    this.excerpt = '',
    this.captures = const {},
  });

  factory Finding.fromJson(JsonReader json) => Finding(
        id: json.string('id'),
        title: json.string('title'),
        cause: json.string('cause'),
        fix: json.string('fix'),
        confidence: enumByName(Confidence.values, json.string('confidence')),
        step: json.string('step'),
        docsUrl: json.optionalString('docsUrl'),
        excerpt: json.optionalString('excerpt') ?? '',
        captures: json
            .optionalObject('captures')
            .json
            .map((k, v) => MapEntry(k, '$v')),
      );

  /// Identifier of the rule that matched, e.g. `UP-AND-0007`.
  /// [unidentifiedId] when no rule matched.
  final String id;
  final String title;
  final String cause;
  final String fix;
  final Confidence confidence;

  /// The verification step whose output was diagnosed.
  final String step;
  final String? docsUrl;

  /// Relevant, redacted lines of the log.
  final String excerpt;

  /// Values captured by the rule pattern (package name, versions...).
  final Map<String, String> captures;

  static const unidentifiedId = 'UP-GEN-0000';

  bool get identified => id != unidentifiedId;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'cause': cause,
        'fix': fix,
        'confidence': confidence.name,
        'step': step,
        'docsUrl': docsUrl,
        'excerpt': excerpt,
        'captures': captures,
      };
}
