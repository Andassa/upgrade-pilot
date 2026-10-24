/// Process exit codes. They are part of the public contract.
abstract final class ExitCodes {
  /// The plan is verified and healthy, or the command succeeded.
  static const ok = 0;

  /// Invalid usage: unknown flag, bad value, missing argument.
  static const usage = 1;

  /// The plan has unresolved blocking problems.
  static const blocked = 2;

  /// A required tool (Flutter, git, Android SDK...) is missing.
  static const environment = 3;

  /// The user interrupted the run (Ctrl+C).
  static const interrupted = 4;

  /// Unexpected internal error.
  static const internal = 70;
}
