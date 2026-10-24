import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/ui/caps.dart';

/// A color with its fallbacks for 256 and 16 color terminals.
@immutable
final class Tint {
  const Tint(this.rgb, this.ansi256, this.ansi16);

  final int rgb;
  final int ansi256;

  /// SGR foreground code, e.g. 35 for magenta.
  final int ansi16;

  int get r => (rgb >> 16) & 0xff;
  int get g => (rgb >> 8) & 0xff;
  int get b => rgb & 0xff;
}

/// The palette: one accent, one neutral, and three status colors that are
/// always paired with a symbol.
abstract final class Palette {
  static const accent = Tint(0xA78BFA, 141, 95);
  static const accentEnd = Tint(0x5EEAD4, 79, 96);
  static const muted = Tint(0x8B8FA3, 245, 90);
  static const ok = Tint(0x4ADE80, 78, 32);
  static const warn = Tint(0xFACC15, 220, 33);
  static const error = Tint(0xF87171, 203, 31);
}

/// Status and structure glyphs, with ASCII fallbacks.
enum Symbols {
  unicode._(
    ok: '✔',
    fail: '✖',
    warn: '▲',
    running: '●',
    info: '◆',
    arrow: '→',
    retry: '↻',
    skip: '─',
    dot: '·',
    ellipsis: '…',
    box: BoxChars.rounded,
    spinner: ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
  ),
  ascii._(
    ok: 'ok',
    fail: 'x',
    warn: '!',
    running: '*',
    info: 'i',
    arrow: '->',
    retry: '~',
    skip: '-',
    dot: '|',
    ellipsis: '...',
    box: BoxChars.ascii,
    spinner: ['-', r'\', '|', '/'],
  );

  const Symbols._({
    required this.ok,
    required this.fail,
    required this.warn,
    required this.running,
    required this.info,
    required this.arrow,
    required this.retry,
    required this.skip,
    required this.dot,
    required this.ellipsis,
    required this.box,
    required this.spinner,
  });

  final String ok;
  final String fail;
  final String warn;
  final String running;
  final String info;
  final String arrow;
  final String retry;
  final String skip;
  final String dot;
  final String ellipsis;
  final BoxChars box;
  final List<String> spinner;
}

enum BoxChars {
  rounded._('╭', '╮', '╰', '╯', '─', '│'),
  ascii._('+', '+', '+', '+', '-', '|');

  const BoxChars._(
    this.topLeft,
    this.topRight,
    this.bottomLeft,
    this.bottomRight,
    this.horizontal,
    this.vertical,
  );

  final String topLeft;
  final String topRight;
  final String bottomLeft;
  final String bottomRight;
  final String horizontal;
  final String vertical;
}

/// Applies colors and weights according to [TerminalCaps].
final class Style {
  Style(this.caps) : symbols = caps.unicode ? Symbols.unicode : Symbols.ascii;

  final TerminalCaps caps;
  final Symbols symbols;

  bool get colored => caps.color != ColorLevel.none;

  String _sgr(String text, String open, String close) =>
      colored && text.isNotEmpty ? '\x1B[${open}m$text\x1B[${close}m' : text;

  String _fg(Tint tint) => switch (caps.color) {
        ColorLevel.truecolor => '38;2;${tint.r};${tint.g};${tint.b}',
        ColorLevel.ansi256 => '38;5;${tint.ansi256}',
        _ => '${tint.ansi16}',
      };

  String tint(String text, Tint tint) => _sgr(text, _fg(tint), '39');
  String bold(String text) => _sgr(text, '1', '22');
  String dim(String text) => tint(text, Palette.muted);
  String accent(String text) => tint(text, Palette.accent);
  String ok(String text) => tint(text, Palette.ok);
  String warn(String text) => tint(text, Palette.warn);
  String error(String text) => tint(text, Palette.error);

  /// Colors each column of [text] along a gradient from [from] to [to].
  /// Falls back to a single accent below 256 colors.
  String gradient(String text, Tint from, Tint to) {
    if (!colored) return text;
    if (caps.color == ColorLevel.ansi16) return tint(text, from);
    final chars = text.runes.toList();
    final buffer = StringBuffer();
    final span = chars.length <= 1 ? 1 : chars.length - 1;
    for (var i = 0; i < chars.length; i++) {
      final char = String.fromCharCode(chars[i]);
      if (char == ' ') {
        buffer.write(char);
        continue;
      }
      final t = i / span;
      final r = (from.r + (to.r - from.r) * t).round();
      final g = (from.g + (to.g - from.g) * t).round();
      final b = (from.b + (to.b - from.b) * t).round();
      final code = caps.color == ColorLevel.truecolor
          ? '38;2;$r;$g;$b'
          : '38;5;${_to256(r, g, b)}';
      buffer.write('\x1B[${code}m$char');
    }
    buffer.write('\x1B[39m');
    return buffer.toString();
  }

  static int _to256(int r, int g, int b) {
    int level(int c) => c < 48 ? 0 : (c < 115 ? 1 : ((c - 35) ~/ 40));
    return 16 + 36 * level(r) + 6 * level(g) + level(b);
  }
}
