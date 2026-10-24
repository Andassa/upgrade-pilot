import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';

/// Outcome of a verification step.
enum StepStatus { ok, warning, failed, skipped }

/// Proof that a command really ran: what, how long, with which result.
@immutable
final class Evidence {
  const Evidence({
    required this.step,
    required this.command,
    required this.status,
    required this.duration,
    required this.attempt,
    this.exitCode,
    this.detail,
    this.excerpt = '',
    this.findingId,
  });

  factory Evidence.fromJson(JsonReader json) => Evidence(
        step: json.string('step'),
        command: json.string('command'),
        status: enumByName(StepStatus.values, json.string('status')),
        duration: Duration(milliseconds: json.integer('durationMs')),
        attempt: json.integer('attempt'),
        exitCode: json.optionalInt('exitCode'),
        detail: json.optionalString('detail'),
        excerpt: json.optionalString('excerpt') ?? '',
        findingId: json.optionalString('findingId'),
      );

  /// Step identifier: `pub get`, `analyze`, `build apk`, `build ios`, `test`.
  final String step;

  /// The redacted command line that was executed.
  final String command;
  final StepStatus status;
  final Duration duration;

  /// 1-based attempt number of the verification loop.
  final int attempt;
  final int? exitCode;

  /// Short detail such as `3 warnings` or `skipped (use --run-tests)`.
  final String? detail;
  final String excerpt;
  final String? findingId;

  Map<String, Object?> toJson() => {
        'step': step,
        'command': command,
        'status': status.name,
        'durationMs': duration.inMilliseconds,
        'attempt': attempt,
        'exitCode': exitCode,
        'detail': detail,
        'excerpt': excerpt,
        'findingId': findingId,
      };
}

/// Something the plan could not verify, with the reason. Always reported.
@immutable
final class NotVerified {
  const NotVerified({required this.what, required this.reason});

  factory NotVerified.fromJson(JsonReader json) =>
      NotVerified(what: json.string('what'), reason: json.string('reason'));

  final String what;
  final String reason;

  Map<String, Object?> toJson() => {'what': what, 'reason': reason};
}
