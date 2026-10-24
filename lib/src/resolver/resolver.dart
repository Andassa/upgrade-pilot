import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';
import 'package:upgrade_pilot/src/resolver/strategy.dart';
import 'package:upgrade_pilot/src/verify/verifier.dart';

/// Bounds of the search.
@immutable
final class ResolverLimits {
  const ResolverLimits({
    required this.deadline,
    this.maxAttempts = 6,
    this.maxDepth = 4,
  });

  final int maxAttempts;

  /// Maximum number of chained automatic fixes.
  final int maxDepth;
  final DateTime deadline;
}

/// Why the search stopped.
enum StopReason {
  success,
  attemptsExhausted,
  timeExhausted,
  noCandidateLeft,
  environment,
  blockedDependency,
  cancelled,
}

@immutable
final class Resolution {
  const Resolution({
    required this.winner,
    required this.lastOutcome,
    required this.attempts,
    required this.evidence,
    required this.findings,
    required this.blocked,
    required this.stopReason,
  });

  /// The candidate whose verification passed, if any.
  final Candidate? winner;
  final AttemptOutcome? lastOutcome;
  final List<AttemptRecord> attempts;
  final List<Evidence> evidence;
  final List<Finding> findings;
  final List<BlockedItem> blocked;
  final StopReason stopReason;
}

typedef RunAttempt = Future<AttemptOutcome> Function(Candidate, int attempt);

/// Depth-first search with backtracking: try a candidate, diagnose the
/// failure, derive fixed candidates, and fall back to the next initial
/// candidate when a branch has no fix left.
final class Resolver {
  Resolver({
    required Strategy strategy,
    required ResolverLimits limits,
    required Clock clock,
    ProgressObserver observer = const SilentObserver(),
  })  : _strategy = strategy,
        _limits = limits,
        _clock = clock,
        _observer = observer;

  final Strategy _strategy;
  final ResolverLimits _limits;
  final Clock _clock;
  final ProgressObserver _observer;

  Future<Resolution> run(
    RunAttempt runAttempt, {
    CancellationToken? cancellation,
  }) async {
    final stack = _strategy.initialCandidates().reversed.toList();
    final seen = <String>{};
    final learned = <String, String>{};
    final attempts = <AttemptRecord>[];
    final evidence = <Evidence>[];
    final findings = <String, Finding>{};
    final blocked = <String, BlockedItem>{};
    AttemptOutcome? last;
    var stop = StopReason.noCandidateLeft;
    Candidate? winner;

    while (stack.isNotEmpty) {
      if (cancellation?.isCancelled ?? false) {
        stop = StopReason.cancelled;
        break;
      }
      if (attempts.length >= _limits.maxAttempts) {
        stop = StopReason.attemptsExhausted;
        break;
      }
      if (!_clock().isBefore(_limits.deadline)) {
        stop = StopReason.timeExhausted;
        break;
      }
      final candidate = stack.removeLast().withConstraints(learned);
      if (!seen.add(candidate.key)) continue;
      final number = attempts.length + 1;
      final changes = candidate.describe(_strategy.context.snapshot);
      _observer.attemptStarted(number, _limits.maxAttempts, changes);
      final outcome = await runAttempt(candidate, number);
      last = outcome;
      evidence.addAll(outcome.evidence);
      final firstFinding =
          outcome.diagnoses.isEmpty ? null : outcome.diagnoses.first.finding;
      attempts.add(
        AttemptRecord(
          number: number,
          description: changes.isEmpty ? 'no change' : changes.join(', '),
          succeeded: outcome.succeeded,
          findingId: firstFinding?.id,
        ),
      );
      if (outcome.cancelled) {
        stop = StopReason.cancelled;
        break;
      }
      if (outcome.succeeded) {
        winner = candidate;
        stop = StopReason.success;
        break;
      }
      for (final d in outcome.diagnoses) {
        findings.putIfAbsent(
          '${d.finding.id}|${d.finding.step}',
          () => d.finding,
        );
      }
      if (outcome.diagnoses.any((d) => d.isEnvironment)) {
        stop = StopReason.environment;
        break;
      }
      final children = <Candidate>[];
      var blockedHere = false;
      for (final diagnosis in outcome.diagnoses) {
        final result = await _strategy.fix(candidate, diagnosis);
        switch (result) {
          case NextCandidate(:final candidate, :final dependencyConstraints):
            learned.addAll(dependencyConstraints);
            if (candidate.depth <= _limits.maxDepth &&
                !seen.contains(candidate.withConstraints(learned).key)) {
              children.add(candidate);
            }
          case Blocked(:final item):
            blocked.putIfAbsent(item.subject, () => item);
            blockedHere = true;
          case NoFix():
            break;
        }
        if (children.isNotEmpty) break;
      }
      if (children.isEmpty &&
          outcome.failedStep == Steps.pubGet &&
          (blockedHere || _onlyDependencyProblems(outcome.diagnoses))) {
        // Dependencies are shared by every candidate: no point in trying
        // other toolchains.
        stop = StopReason.blockedDependency;
        break;
      }
      stack.addAll(children.reversed);
    }

    return Resolution(
      winner: winner,
      lastOutcome: last,
      attempts: attempts,
      evidence: evidence,
      findings: findings.values.toList(),
      blocked: blocked.values.toList(),
      stopReason: stack.isEmpty && stop == StopReason.noCandidateLeft
          ? StopReason.noCandidateLeft
          : stop,
    );
  }

  static bool _onlyDependencyProblems(List<Diagnosis> diagnoses) =>
      diagnoses.every((d) => d.category == 'pub' || !d.finding.identified);
}
