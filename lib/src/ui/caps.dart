import 'package:meta/meta.dart';

/// How many colors the terminal can show.
enum ColorLevel { none, ansi16, ansi256, truecolor }

/// What the output terminal supports. Built once from the environment.
@immutable
final class TerminalCaps {
  const TerminalCaps({
    required this.color,
    required this.unicode,
    required this.width,
    required this.interactive,
  });

  /// Detects capabilities. [columns] is `null` when stdout is not a TTY.
  factory TerminalCaps.detect({
    required Map<String, String> environment,
    required bool stdoutIsTty,
    required int? columns,
    required bool isWindows,
    bool noColorFlag = false,
    bool ciFlag = false,
    bool asciiFlag = false,
  }) {
    final term = environment['TERM'] ?? '';
    final dumb = term == 'dumb';
    final ci = ciFlag || _isCi(environment);
    final noColor = noColorFlag ||
        (environment['NO_COLOR']?.isNotEmpty ?? false) ||
        dumb ||
        !stdoutIsTty;
    final forceColor = environment['FORCE_COLOR'];
    ColorLevel color;
    if (forceColor != null && forceColor != '0' && !noColorFlag) {
      color = _levelFrom(environment, isWindows);
    } else if (noColor) {
      color = ColorLevel.none;
    } else {
      color = _levelFrom(environment, isWindows);
    }
    final lang = '${environment['LC_ALL'] ?? ''}${environment['LANG'] ?? ''}'
        .toUpperCase();
    final unicode = !asciiFlag &&
        !dumb &&
        (isWindows
            ? environment.containsKey('WT_SESSION') ||
                environment['TERM_PROGRAM'] == 'vscode'
            : lang.isEmpty || lang.contains('UTF'));
    return TerminalCaps(
      color: color,
      unicode: unicode,
      width: clampWidth(columns ?? defaultWidth),
      interactive: stdoutIsTty && !ci && !dumb,
    );
  }

  /// Plain output: no color, ASCII, not interactive.
  static const plain = TerminalCaps(
    color: ColorLevel.none,
    unicode: false,
    width: defaultWidth,
    interactive: false,
  );

  static const defaultWidth = 80;
  static const minWidth = 40;
  static const maxWidth = 120;

  final ColorLevel color;
  final bool unicode;

  /// Usable width, clamped to [minWidth]..[maxWidth].
  final int width;

  /// Animations and in-place updates are allowed.
  final bool interactive;

  static int clampWidth(int columns) => columns.clamp(minWidth, maxWidth);

  TerminalCaps copyWith({
    ColorLevel? color,
    bool? unicode,
    int? width,
    bool? interactive,
  }) =>
      TerminalCaps(
        color: color ?? this.color,
        unicode: unicode ?? this.unicode,
        width: width ?? this.width,
        interactive: interactive ?? this.interactive,
      );

  static bool _isCi(Map<String, String> env) {
    final ci = env['CI'];
    if (ci != null && ci != 'false' && ci != '0') return true;
    return const [
      'GITHUB_ACTIONS',
      'GITLAB_CI',
      'BUILDKITE',
      'CIRCLECI',
      'TF_BUILD',
      'JENKINS_URL',
      'TEAMCITY_VERSION',
      'BITRISE_IO',
      'CODEMAGIC',
    ].any(env.containsKey);
  }

  static ColorLevel _levelFrom(Map<String, String> env, bool isWindows) {
    final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
    if (colorterm == 'truecolor' || colorterm == '24bit') {
      return ColorLevel.truecolor;
    }
    final program = env['TERM_PROGRAM'] ?? '';
    if (const ['iTerm.app', 'WezTerm', 'vscode', 'ghostty'].contains(program)) {
      return ColorLevel.truecolor;
    }
    if (isWindows && env.containsKey('WT_SESSION')) return ColorLevel.truecolor;
    if ((env['TERM'] ?? '').contains('256')) return ColorLevel.ansi256;
    return ColorLevel.ansi16;
  }
}
