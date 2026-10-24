import 'dart:async';

import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';

/// Identifiers of verification steps, also shown to the user.
abstract final class Steps {
  static const pubGet = 'pub get';
  static const analyze = 'analyze';
  static const buildApk = 'build apk';
  static const buildIos = 'build ios';
  static const test = 'test';

  static const List<String> all = [pubGet, analyze, buildApk, buildIos, test];

  static List<String> arguments(String step) => switch (step) {
        pubGet => const ['pub', 'get'],
        analyze => const ['analyze', '--no-fatal-infos', '--no-fatal-warnings'],
        buildApk => const ['build', 'apk', '--debug'],
        buildIos => const ['build', 'ios', '--debug', '--no-codesign'],
        test => const ['test'],
        _ => throw ArgumentError.value(step, 'step'),
      };
}

/// Which steps run, and why the others do not.
@immutable
final class VerifyPlan {
  const VerifyPlan({required this.steps, this.skipped = const {}});

  /// Steps to run, in order. `pub get` always comes first.
  final List<String> steps;

  /// Step → reason it is not run.
  final Map<String, String> skipped;
}

/// Result of one verification attempt.
@immutable
final class AttemptOutcome {
  const AttemptOutcome({
    required this.evidence,
    required this.diagnoses,
    this.failedStep,
    this.cancelled = false,
  });

  final List<Evidence> evidence;

  /// Diagnoses of the failed step, in rule priority order.
  final List<Diagnosis> diagnoses;
  final String? failedStep;
  final bool cancelled;

  bool get succeeded => failedStep == null && !cancelled;
  bool get hasWarnings => evidence.any((e) => e.status == StepStatus.warning);
}

final _analyzerIssue =
    RegExp(r'^\s*(error|warning|info)\s+[•-]\s', multiLine: true);

/// Runs Flutter commands in the sandbox with the target SDK, and turns
/// every failure into a diagnosis.
final class Verifier {
  Verifier({
    required ProcessRunner runner,
    required Diagnoser diagnoser,
    required Redactor redactor,
    required Clock clock,
  })  : _runner = runner,
        _diagnoser = diagnoser,
        _redactor = redactor,
        _clock = clock;

  final ProcessRunner _runner;
  final Diagnoser _diagnoser;
  final Redactor _redactor;
  final Clock _clock;

  static const timeoutId = 'UP-GEN-0001';

  Future<AttemptOutcome> verify({
    required String projectDirectory,
    required String flutter,
    required Map<String, String> environment,
    required VerifyPlan plan,
    required int attempt,
    required DateTime deadline,
    required ProgressObserver observer,
    CancellationToken? cancellation,
    int jobs = 1,
  }) async {
    final evidence = <Evidence>[];
    final diagnoses = <Diagnosis>[];
    String? failed;

    Future<void> runStep(String step) async {
      final remaining = deadline.difference(_clock());
      if (remaining <= Duration.zero) {
        evidence.add(_skipped(step, attempt, 'time budget exhausted'));
        observer.stepFinished(evidence.last);
        failed ??= step;
        diagnoses.add(_timeout(step));
        return;
      }
      observer.stepStarted(step);
      final args = [...Steps.arguments(step), '--suppress-analytics'];
      final outcome = await _runner.run(
        Command(
          flutter,
          args,
          workingDirectory: projectDirectory,
          environment: environment,
          timeout: remaining,
        ),
        cancellation: cancellation,
      );
      final display = 'flutter ${Steps.arguments(step).join(' ')}';
      final result = _evaluate(step, display, outcome, attempt);
      evidence.add(result.$1);
      observer.stepFinished(result.$1);
      if (result.$2.isNotEmpty) {
        failed ??= step;
        diagnoses.addAll(result.$2);
      }
    }

    final steps = plan.steps;
    if (steps.isEmpty) {
      return AttemptOutcome(evidence: evidence, diagnoses: diagnoses);
    }
    await runStep(steps.first);
    final rest = steps.skip(1).toList();
    if (failed == null && !(cancellation?.isCancelled ?? false)) {
      if (jobs <= 1) {
        for (final step in rest) {
          if (cancellation?.isCancelled ?? false) break;
          if (failed != null) {
            evidence.add(_skipped(step, attempt, 'an earlier step failed'));
            observer.stepFinished(evidence.last);
            continue;
          }
          await runStep(step);
        }
      } else {
        final queue = [...rest];
        Future<void> worker() async {
          while (queue.isNotEmpty && !(cancellation?.isCancelled ?? false)) {
            await runStep(queue.removeAt(0));
          }
        }

        await Future.wait([for (var i = 0; i < jobs; i++) worker()]);
      }
    } else {
      for (final step in rest) {
        evidence.add(_skipped(step, attempt, 'an earlier step failed'));
        observer.stepFinished(evidence.last);
      }
    }
    final cancelled = cancellation?.isCancelled ?? false;
    return AttemptOutcome(
      evidence: evidence,
      diagnoses: diagnoses,
      failedStep: failed,
      cancelled: cancelled,
    );
  }

  Evidence _skipped(String step, int attempt, String reason) => Evidence(
        step: step,
        command: 'flutter ${Steps.arguments(step).join(' ')}',
        status: StepStatus.skipped,
        duration: Duration.zero,
        attempt: attempt,
        detail: reason,
      );

  Diagnosis _timeout(String step) => Diagnosis(
        Finding(
          id: timeoutId,
          title: 'Time budget exhausted',
          cause: 'The step "$step" did not finish within the --timeout budget.',
          fix: 'Run plan again with a larger --timeout.',
          confidence: Confidence.high,
          step: step,
        ),
        FixAction.none,
        category: 'environment',
      );

  (Evidence, List<Diagnosis>) _evaluate(
    String step,
    String display,
    ProcessOutcome outcome,
    int attempt,
  ) {
    Evidence evidence(
      StepStatus status, {
      String? detail,
      String excerpt = '',
      String? findingId,
    }) =>
        Evidence(
          step: step,
          command: display,
          status: status,
          duration: outcome.duration,
          attempt: attempt,
          exitCode: outcome.exitCode,
          detail: detail,
          excerpt: excerpt,
          findingId: findingId,
        );

    if (outcome.timedOut) {
      final diagnosis = _timeout(step);
      return (
        evidence(StepStatus.failed, detail: 'timed out', findingId: timeoutId),
        [diagnosis],
      );
    }
    if (outcome.cancelled) {
      return (evidence(StepStatus.skipped, detail: 'interrupted'), const []);
    }
    if (step == Steps.analyze) return (_analyze(outcome, evidence), const []);
    if (outcome.succeeded) return (evidence(StepStatus.ok), const []);
    final diagnoses = _diagnoser.diagnose(step: step, output: outcome.output);
    final first = diagnoses.first.finding;
    return (
      evidence(
        StepStatus.failed,
        detail: first.identified ? first.id : 'exit code ${outcome.exitCode}',
        excerpt: first.excerpt,
        findingId: first.id,
      ),
      diagnoses,
    );
  }

  Evidence _analyze(
    ProcessOutcome outcome,
    Evidence Function(
      StepStatus, {
      String? detail,
      String excerpt,
      String? findingId,
    }) evidence,
  ) {
    final issues = _analyzerIssue.allMatches(outcome.output).toList();
    int count(String severity) =>
        issues.where((m) => m.group(1) == severity).length;
    final errors = count('error');
    final warnings = count('warning');
    final infos = count('info');
    final lines = outcome.output
        .split('\n')
        .where(_analyzerIssue.hasMatch)
        .take(8)
        .join('\n');
    final excerpt = _redactor.redact(lines);
    if (errors > 0 || warnings > 0) {
      final parts = [
        if (errors > 0) '$errors ${errors == 1 ? 'error' : 'errors'}',
        if (warnings > 0) '$warnings ${warnings == 1 ? 'warning' : 'warnings'}',
      ];
      return evidence(
        StepStatus.warning,
        detail: parts.join(', '),
        excerpt: excerpt,
      );
    }
    if (!outcome.succeeded && issues.isEmpty) {
      return evidence(
        StepStatus.warning,
        detail: 'analyzer exited with ${outcome.exitCode}',
        excerpt:
            _redactor.redact(outcome.output.split('\n').take(8).join('\n')),
      );
    }
    return evidence(
      StepStatus.ok,
      detail: infos > 0 ? '$infos ${infos == 1 ? 'info' : 'infos'}' : null,
    );
  }
}
