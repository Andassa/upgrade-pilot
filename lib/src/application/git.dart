import 'package:upgrade_pilot/src/ports/ports.dart';

/// Minimal read-only git queries.
final class GitClient {
  GitClient(this._runner, this._environment);

  final ProcessRunner _runner;
  final Map<String, String> _environment;

  Map<String, String> get _env => {
        for (final key in const ['PATH', 'HOME', 'USERPROFILE', 'SystemRoot'])
          if (_environment[key] case final value?) key: value,
        'GIT_TERMINAL_PROMPT': '0',
      };

  Future<ProcessOutcome?> _git(String dir, List<String> args) async {
    try {
      return await _runner.run(
        Command(
          'git',
          ['-C', dir, ...args],
          environment: _env,
          timeout: const Duration(seconds: 30),
        ),
      );
    } on ProcessStartException {
      return null;
    }
  }

  Future<bool> isRepository(String dir) async =>
      (await _git(dir, const ['rev-parse', '--is-inside-work-tree']))
          ?.stdout
          .trim() ==
      'true';

  /// `true` when there are no staged, unstaged or untracked changes.
  Future<bool> isClean(String dir) async {
    final outcome = await _git(dir, const ['status', '--porcelain']);
    return outcome != null &&
        outcome.succeeded &&
        outcome.stdout.trim().isEmpty;
  }

  Future<String?> head(String dir) async {
    final outcome = await _git(dir, const ['rev-parse', 'HEAD']);
    if (outcome == null || !outcome.succeeded) return null;
    final sha = outcome.stdout.trim();
    return sha.isEmpty ? null : sha;
  }
}
