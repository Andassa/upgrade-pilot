import 'package:upgrade_pilot/src/domain/evidence.dart';

/// Receives progress events. Implemented by the terminal UI; use cases
/// never print. Labels are looked up by the UI from `stage.<id>` keys, so
/// events carry identifiers and arguments, not sentences.
abstract interface class ProgressObserver {
  /// The project and target are known (after inspection and resolution).
  void planContext({
    required String project,
    required String? from,
    required String target,
    required List<String> platforms,
  });

  void stageStarted(String id, {Map<String, Object?> args = const {}});

  /// Updates the detail of a running stage (e.g. download progress).
  void stageProgress(String id, String detail);

  /// [labelKey] replaces `stage.<id>` (e.g. once the target is resolved).
  /// [detailKey] names a `detail.*` text filled with [args].
  void stageFinished(
    String id,
    StepStatus status, {
    String? labelKey,
    String? detailKey,
    Map<String, Object?> args = const {},
    Duration? duration,
  });

  /// A verification attempt starts. [changes] describes the candidate.
  void attemptStarted(int number, int max, List<String> changes);

  void stepStarted(String step);
  void stepFinished(Evidence evidence);
}

/// Ignores every event.
final class SilentObserver implements ProgressObserver {
  const SilentObserver();

  @override
  void planContext({
    required String project,
    required String? from,
    required String target,
    required List<String> platforms,
  }) {}
  @override
  void stageStarted(String id, {Map<String, Object?> args = const {}}) {}
  @override
  void stageProgress(String id, String detail) {}
  @override
  void stageFinished(
    String id,
    StepStatus status, {
    String? labelKey,
    String? detailKey,
    Map<String, Object?> args = const {},
    Duration? duration,
  }) {}
  @override
  void attemptStarted(int number, int max, List<String> changes) {}
  @override
  void stepStarted(String step) {}
  @override
  void stepFinished(Evidence evidence) {}
}
