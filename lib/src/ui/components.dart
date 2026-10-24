import 'dart:math' as math;

import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/ui/caps.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';
import 'package:upgrade_pilot/src/ui/style.dart';
import 'package:upgrade_pilot/src/ui/text.dart';

/// Kinds of row markers. Status is never conveyed by color alone.
enum Mark { ok, fail, warn, running, info, arrow, retry, skip }

/// Pure renderers: every method returns text, nothing is printed here.
final class Ui {
  Ui(this.style, this.strings);

  final Style style;
  final Strings strings;

  static const margin = '  ';
  static const _labelColumn = 26;

  TerminalCaps get caps => style.caps;
  Symbols get symbols => style.symbols;

  /// Width used for aligned layouts (wider terminals keep it readable).
  int get contentWidth => math.min(caps.width, 100) - margin.length;

  static const _asciiMap = {
    '→': '->',
    '·': '|',
    '…': '...',
    '✔': 'ok',
    '✖': 'x',
    '▲': '!',
    '●': '*',
    '◆': 'i',
    '↻': '~',
    '─': '-',
    '│': '|',
    '╭': '+',
    '╮': '+',
    '╰': '+',
    '╯': '+',
    '’': "'",
  };

  /// Replaces Unicode glyphs found in dynamic texts (summaries, rule
  /// texts) when the terminal only supports ASCII.
  String safe(String text) {
    if (caps.unicode) return text;
    var result = text;
    for (final MapEntry(:key, :value) in _asciiMap.entries) {
      result = result.replaceAll(key, value);
    }
    return result;
  }

  String mark(Mark mark) => switch (mark) {
        Mark.ok => style.ok(symbols.ok),
        Mark.fail => style.error(symbols.fail),
        Mark.warn => style.warn(symbols.warn),
        Mark.running => style.accent(symbols.running),
        Mark.info => style.accent(symbols.info),
        Mark.arrow => style.accent(symbols.arrow),
        Mark.retry => style.accent(symbols.retry),
        Mark.skip => style.dim(symbols.skip),
      };

  static Mark markFor(StepStatus status) => switch (status) {
        StepStatus.ok => Mark.ok,
        StepStatus.warning => Mark.warn,
        StepStatus.failed => Mark.fail,
        StepStatus.skipped => Mark.skip,
      };

  /// `upgrade-pilot 1.0.0 · plan`
  String header(String version, {String? command}) {
    final name = style.bold(style.accent('upgrade-pilot'));
    final tail = command == null ? '' : ' ${style.dim(symbols.dot)} $command';
    return '$name ${style.dim(version)}$tail';
  }

  /// The project / target block printed above the progress.
  List<String> planContext({
    required String project,
    required String? from,
    required String target,
    required List<String> platforms,
  }) {
    final arrow = style.accent(symbols.arrow);
    final version = from == null
        ? style.bold(target)
        : '$from  $arrow  ${style.bold(target)}';
    return keyValues([
      (
        strings('label.project'),
        '${style.bold(project)}  ${style.dim(symbols.dot)}  Flutter $version',
      ),
      (
        strings('label.platforms'),
        platforms.isEmpty ? '-' : platforms.join(', ')
      ),
      (strings('label.sandbox'), style.dim(strings('sandbox.note'))),
    ]);
  }

  /// Aligned `label  value` rows.
  List<String> keyValues(List<(String, String)> rows) {
    final width = rows.fold(0, (w, r) => math.max(w, visibleLength(r.$1)));
    return [
      for (final (key, value) in rows)
        '$margin${style.dim(padRight(key, width))}  $value',
    ];
  }

  /// A step row: mark, label, detail and a right-aligned duration.
  String row(
    Mark kind,
    String label, {
    String? detail,
    Duration? duration,
    int indent = 0,
  }) {
    final prefix = '$margin${' ' * indent}${mark(kind)} ';
    final time = duration == null ? '' : formatDuration(duration);
    final available = contentWidth + margin.length - visibleLength(prefix);
    final labelText = detail == null
        ? label
        : padRight(
            label,
            math.max(_labelColumn - indent, visibleLength(label) + 1),
          );
    var body =
        detail == null ? labelText : '$labelText${_detail(kind, detail)}';
    final room = available - time.length - 1;
    if (visibleLength(body) > room) {
      body = truncate(stripAnsi(body), room, ellipsis: symbols.ellipsis);
    }
    if (time.isEmpty) return '$prefix$body';
    final gap = math.max(1, available - visibleLength(body) - time.length);
    return '$prefix$body${' ' * gap}${style.dim(time)}';
  }

  String _detail(Mark kind, String detail) => switch (kind) {
        Mark.fail => style.error(detail),
        Mark.warn => style.warn(detail),
        _ => style.dim(detail),
      };

  /// A rounded panel, e.g. the plan summary.
  List<String> panel(String title, List<String> lines, {Tint? tone}) {
    final box = symbols.box;
    final inner = math.min(
      contentWidth - 2,
      math.max(
        visibleLength(title) + 4,
        lines.fold(0, (w, l) => math.max(w, visibleLength(l))) + 2,
      ),
    );
    String border(String s) =>
        tone == null ? style.dim(s) : style.tint(s, tone);
    final titleText = ' ${style.bold(title)} ';
    final fill = math.max(0, inner - visibleLength(titleText) - 1);
    final side = border(box.vertical);
    final top = border('${box.topLeft}${box.horizontal}');
    final topEnd = border('${box.horizontal * fill}${box.topRight}');
    final bottom = border(
      '${box.bottomLeft}${box.horizontal * inner}${box.bottomRight}',
    );
    return [
      '$margin$top$titleText$topEnd',
      for (final line in lines)
        '$margin$side ${padRight(_fit(line, inner - 2), inner - 2)} $side',
      '$margin$bottom',
    ];
  }

  /// A single marked line: `  ✔ text`.
  String line(Mark kind, String text) => '$margin${mark(kind)} $text';

  /// A dimmed hint under a marked line.
  String hint(String text, {int indent = 2}) =>
      '$margin${' ' * indent}${style.dim(text)}';

  String _fit(String line, int width) => visibleLength(line) <= width
      ? line
      : truncate(stripAnsi(line), width, ellipsis: symbols.ellipsis);

  String section(String title) => '$margin${style.bold(title)}';

  /// Word-wrapped text with a hanging indent under the first line.
  List<String> paragraph(
    String text, {
    int indent = 0,
    String? Function(String)? paint,
  }) {
    final width = math.max(20, contentWidth - indent);
    return [
      for (final line in wrap(text, width))
        '$margin${' ' * indent}${paint == null ? line : paint(line) ?? line}',
    ];
  }

  /// A marked item whose text wraps under itself.
  List<String> bullet(Mark kind, String text, {int indent = 0}) {
    final pad = ' ' * indent;
    final lines = wrap(text, math.max(20, contentWidth - indent - 2));
    return [
      if (lines.isNotEmpty) '$margin$pad${mark(kind)} ${lines.first}',
      for (final line in lines.skip(1)) '$margin$pad  $line',
    ];
  }

  /// The fixed error format: title, why, what to do, more info.
  List<String> error({
    required String title,
    String? why,
    String? fix,
    String? more,
  }) {
    final labelWidth = [
      strings('error.why'),
      strings('error.fix'),
      strings('error.more'),
    ].fold(0, (w, s) => math.max(w, s.length));
    List<String> field(String label, String value) {
      final lines = wrap(value, math.max(20, contentWidth - labelWidth - 4));
      final head = style.dim(padRight(label, labelWidth));
      final blank = ' ' * labelWidth;
      return [
        for (var i = 0; i < lines.length; i++)
          '$margin  ${i == 0 ? head : blank}  ${lines[i]}',
      ];
    }

    return [
      '$margin${mark(Mark.fail)} ${style.bold(title)}',
      if (why != null) ...field(strings('error.why'), why),
      if (fix != null) ...field(strings('error.fix'), fix),
      if (more != null) ...field(strings('error.more'), style.accent(more)),
    ];
  }

  /// `Next  cmd1  ·  cmd2`
  String next(List<String> commands) {
    final sep = '   ${style.dim(symbols.dot)}   ';
    return '$margin${style.bold(strings('section.next'))}   '
        '${commands.map(style.accent).join(sep)}';
  }

  // 3x5 pixel glyphs rendered with half blocks (two pixel rows per line).
  static const _glyphs = <String, List<String>>{
    'u': ['#.#', '#.#', '#.#', '#.#', '###'],
    'p': ['###', '#.#', '###', '#..', '#..'],
    'g': ['###', '#..', '#.#', '#.#', '###'],
    'r': ['###', '#.#', '##.', '#.#', '#.#'],
    'a': ['###', '#.#', '###', '#.#', '#.#'],
    'd': ['##.', '#.#', '#.#', '#.#', '##.'],
    'e': ['###', '#..', '##.', '#..', '###'],
    '-': ['...', '...', '###', '...', '...'],
    'i': ['###', '.#.', '.#.', '.#.', '###'],
    'l': ['#..', '#..', '#..', '#..', '###'],
    'o': ['###', '#.#', '#.#', '#.#', '###'],
    't': ['###', '.#.', '.#.', '.#.', '.#.'],
  };

  /// The block-letter wordmark, 3 lines high. ASCII terminals get a
  /// plain text title instead.
  List<String> wordmark(String text) {
    if (!caps.unicode) return ['$margin${style.bold(style.accent(text))}'];
    final rows = List.generate(3, (_) => StringBuffer());
    for (final char in text.split('')) {
      final glyph = _glyphs[char];
      if (glyph == null) continue;
      final pixels = [...glyph, '...'];
      for (var line = 0; line < 3; line++) {
        final top = pixels[line * 2];
        final bottom = pixels[line * 2 + 1];
        for (var x = 0; x < 3; x++) {
          final t = top[x] == '#';
          final b = bottom[x] == '#';
          rows[line].write(
            t && b
                ? '█'
                : t
                    ? '▀'
                    : b
                        ? '▄'
                        : ' ',
          );
        }
        rows[line].write(' ');
      }
    }
    String paint(StringBuffer row) => style.gradient(
          row.toString().trimRight(),
          Palette.accent,
          Palette.accentEnd,
        );
    return [for (final row in rows) '$margin${paint(row)}'];
  }

  /// The screen shown by `upgrade-pilot` without arguments.
  List<String> welcome({required String version, required String kbVersion}) {
    final dot = symbols.dot;
    final footer =
        'v$version $dot KB $kbVersion $dot ${strings('welcome.footer')}';
    final commands = [
      ('doctor', strings('welcome.doctor')),
      ('plan', strings('welcome.plan')),
      ('report --open', strings('welcome.report')),
      ('apply', strings('welcome.apply')),
    ];
    final width = commands.fold(0, (w, c) => math.max(w, c.$1.length));
    final lines = [
      '',
      for (final (command, help) in commands)
        [
          style.accent('upgrade-pilot'),
          padRight(command, width),
          ' ',
          style.dim(help),
        ].join(' '),
      '',
    ];
    return [
      '',
      ...wordmark('upgrade-pilot'),
      '',
      ...paragraph(strings('tagline'), paint: style.dim),
      '',
      ...panel(
        '${style.accent(symbols.info)} ${strings('welcome.title')}',
        lines,
      ),
      '',
      '$margin${style.dim(footer)}',
      '$margin${style.dim(
        strings('welcome.help', {
          'command': style.accent('upgrade-pilot --help'),
        }),
      )}',
      '',
    ];
  }
}
