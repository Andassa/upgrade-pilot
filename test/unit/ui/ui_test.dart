import 'package:test/test.dart';
import 'package:upgrade_pilot/src/ui/caps.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';
import 'package:upgrade_pilot/src/ui/style.dart';
import 'package:upgrade_pilot/src/ui/text.dart';

TerminalCaps detect(
  Map<String, String> env, {
  bool tty = true,
  int? columns = 100,
  bool windows = false,
  bool noColor = false,
  bool ci = false,
  bool ascii = false,
}) =>
    TerminalCaps.detect(
      environment: env,
      stdoutIsTty: tty,
      columns: columns,
      isWindows: windows,
      noColorFlag: noColor,
      ciFlag: ci,
      asciiFlag: ascii,
    );

void main() {
  group('TerminalCaps.detect', () {
    const utf8Env = {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color'};

    test('interactive color terminal', () {
      final caps = detect(utf8Env);
      expect(caps.color, ColorLevel.ansi256);
      expect(caps.unicode, isTrue);
      expect(caps.interactive, isTrue);
      expect(caps.width, 100);
      expect(
        detect({...utf8Env, 'COLORTERM': 'truecolor'}).color,
        ColorLevel.truecolor,
      );
      expect(detect({'TERM_PROGRAM': 'iTerm.app'}).color, ColorLevel.truecolor);
      expect(detect({'TERM': 'xterm'}).color, ColorLevel.ansi16);
    });

    test('NO_COLOR, --no-color, non-TTY and dumb terminals', () {
      expect(detect({...utf8Env, 'NO_COLOR': '1'}).color, ColorLevel.none);
      expect(detect(utf8Env, noColor: true).color, ColorLevel.none);
      final pipe = detect(utf8Env, tty: false, columns: null);
      expect(pipe.color, ColorLevel.none);
      expect(pipe.interactive, isFalse);
      expect(pipe.width, TerminalCaps.defaultWidth);
      final dumb = detect({'TERM': 'dumb', 'LANG': 'C.UTF-8'});
      expect(dumb.color, ColorLevel.none);
      expect(dumb.unicode, isFalse);
      expect(dumb.interactive, isFalse);
    });

    test('FORCE_COLOR overrides a pipe, but not --no-color', () {
      expect(
        detect({'FORCE_COLOR': '1'}, tty: false).color,
        isNot(ColorLevel.none),
      );
      expect(detect({'FORCE_COLOR': '0'}, tty: false).color, ColorLevel.none);
      expect(
        detect({'FORCE_COLOR': '1'}, noColor: true).color,
        ColorLevel.none,
      );
    });

    test('CI disables animations', () {
      expect(detect({...utf8Env, 'CI': 'true'}).interactive, isFalse);
      expect(detect({...utf8Env, 'CI': 'false'}).interactive, isTrue);
      expect(
        detect({...utf8Env, 'GITHUB_ACTIONS': 'true'}).interactive,
        isFalse,
      );
      expect(detect(utf8Env, ci: true).interactive, isFalse);
    });

    test('ASCII fallback', () {
      expect(detect({'LANG': 'C'}).unicode, isFalse);
      expect(detect(utf8Env, ascii: true).unicode, isFalse);
      expect(detect({}, windows: true).unicode, isFalse);
      expect(detect({'WT_SESSION': '1'}, windows: true).unicode, isTrue);
      expect(
        detect({'WT_SESSION': '1'}, windows: true).color,
        ColorLevel.truecolor,
      );
    });

    test('width is clamped', () {
      expect(detect(utf8Env, columns: 20).width, TerminalCaps.minWidth);
      expect(detect(utf8Env, columns: 300).width, TerminalCaps.maxWidth);
      expect(TerminalCaps.plain.copyWith(width: 90).width, 90);
    });
  });

  group('text', () {
    test('ANSI aware lengths and padding', () {
      const colored = '\x1B[32mok\x1B[39m';
      expect(stripAnsi(colored), 'ok');
      expect(visibleLength(colored), 2);
      expect(padRight(colored, 4), '$colored  ');
      expect(padLeft('ab', 4), '  ab');
      expect(padLeft('abcdef', 2), 'abcdef');
      expect(truncate('abcdef', 4), 'abc…');
      expect(truncate('abc', 4), 'abc');
    });

    test('wrap', () {
      expect(wrap('aaa bbb ccc', 7), ['aaa bbb', 'ccc']);
      expect(wrap('abcdefghij', 4), ['abcd', 'efgh', 'ij']);
      expect(wrap('a\nb', 10), ['a', 'b']);
      expect(wrap('', 10), ['']);
      expect(wrap('xx abcdefghij', 4), ['xx', 'abcd', 'efgh', 'ij']);
    });

    test('durations and bytes', () {
      expect(formatDuration(const Duration(milliseconds: 420)), '0.4s');
      expect(formatDuration(const Duration(seconds: 98)), '1m 38s');
      expect(formatDuration(const Duration(minutes: 75)), '1h 15m');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(4 * 1024 * 1024 * 1024), '4.0 GB');
    });
  });

  group('style', () {
    test('colors only when allowed', () {
      final plain = Style(TerminalCaps.plain);
      expect(plain.ok('x'), 'x');
      expect(plain.gradient('abc', Palette.accent, Palette.accentEnd), 'abc');
      final c16 = Style(TerminalCaps.plain.copyWith(color: ColorLevel.ansi16));
      expect(c16.error('x'), '\x1B[31mx\x1B[39m');
      expect(
        c16.gradient('ab', Palette.accent, Palette.accentEnd),
        startsWith('\x1B[95m'),
      );
      expect(c16.bold(''), '');
      final c256 =
          Style(TerminalCaps.plain.copyWith(color: ColorLevel.ansi256));
      expect(c256.accent('x'), '\x1B[38;5;141mx\x1B[39m');
      expect(
        c256.gradient('a b', Palette.accent, Palette.accentEnd),
        contains('38;5;'),
      );
      final rgb =
          Style(TerminalCaps.plain.copyWith(color: ColorLevel.truecolor));
      expect(rgb.dim('x'), contains('38;2;139;143;163'));
      expect(
        rgb.gradient('ab', Palette.accent, Palette.accentEnd),
        contains('38;2;94;234;212'),
      );
      expect(
        rgb.gradient('a', Palette.accent, Palette.accentEnd),
        contains('38;2;167;139;250'),
      );
    });

    test('symbols have ASCII fallbacks', () {
      expect(Style(TerminalCaps.plain).symbols.ok, 'ok');
      expect(Style(TerminalCaps.plain.copyWith(unicode: true)).symbols.ok, '✔');
    });
  });

  group('strings', () {
    test('French covers every English key with the same placeholders', () {
      final placeholder = RegExp(r'\{(\w+)\}');
      Set<String> names(String s) =>
          placeholder.allMatches(s).map((m) => m.group(1)!).toSet();
      expect(Strings.fr.keys.toSet(), Strings.en.keys.toSet());
      for (final key in Strings.en.keys) {
        expect(names(Strings.fr[key]!), names(Strings.en[key]!), reason: key);
      }
    });

    test('lookup, plural and fallback', () {
      final en = Strings.of(null);
      final fr = Strings.of('fr_FR');
      expect(en.locale, 'en');
      expect(fr.locale, 'fr');
      expect(Strings.of('de').locale, 'en');
      expect(en.plural('panel.changes', 1), '1 change');
      expect(fr.plural('panel.changes', 3), '3 modifications');
      expect(en('missing.key'), 'missing.key');
      expect(en('welcome.help', {}), contains('{command}'));
      expect(en.has('tagline'), isTrue);
      expect(en.has('nope'), isFalse);
    });
  });

  group('Ui', () {
    final ui = Ui(Style(TerminalCaps.plain), Strings.of('en'));

    test('rows align durations on the right edge', () {
      final a =
          ui.row(Mark.ok, 'pub get', duration: const Duration(seconds: 9));
      final b = ui.row(
        Mark.fail,
        'build apk',
        detail: 'UP-AND-0007',
        duration: const Duration(seconds: 41),
      );
      expect(a.length, b.length);
      expect(b, contains('UP-AND-0007'));
      final long =
          ui.row(Mark.ok, 'x' * 200, duration: const Duration(seconds: 1));
      expect(
        visibleLength(long),
        lessThanOrEqualTo(ui.contentWidth + Ui.margin.length),
      );
      expect(ui.row(Mark.skip, 'tests'), '  - tests');
    });

    test('safe() converts glyphs in ASCII mode only', () {
      expect(ui.safe('AGP 8.1 → 9.0 · ✔'), 'AGP 8.1 -> 9.0 | ok');
      final unicode = Ui(
        Style(TerminalCaps.plain.copyWith(unicode: true)),
        Strings.of('en'),
      );
      expect(unicode.safe('→'), '→');
    });

    test('panel lines never overflow', () {
      final lines = ui.panel('Title', ['x' * 300]);
      for (final line in lines) {
        expect(
          visibleLength(line),
          lessThanOrEqualTo(ui.contentWidth + Ui.margin.length),
        );
      }
    });
  });
}
