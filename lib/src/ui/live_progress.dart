import 'dart:async';

import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/text.dart';

/// Writes raw text to the terminal.
typedef TerminalWrite = void Function(String text);

/// Translates the known step details recorded in plans (English) and
/// keeps the others (rule ids, analyzer counts) as they are.
String? stepDetail(Ui ui, String? raw) {
  if (raw == null) return null;
  for (final key in ['step.skipped.$raw', 'detail.$raw']) {
    if (ui.strings.has(key)) return ui.strings(key);
  }
  return raw;
}

final class _Running {
  _Running(this.label, this.started, this.indent);

  final String label;
  final DateTime started;
  final int indent;
  String? detail;
}

/// Renders progress events. Interactive terminals get a spinner on a
/// single status line; other outputs get stable, timestamped lines.
final class LiveProgress implements ProgressObserver {
  LiveProgress(
    this.ui,
    this._write, {
    required Clock clock,
    Duration tick = const Duration(milliseconds: 80),
  })  : _clock = clock,
        _tick = tick;

  final Ui ui;
  final TerminalWrite _write;
  final Clock _clock;
  final Duration _tick;

  final _running = <String, _Running>{};
  Timer? _timer;
  var _frame = 0;
  var _statusVisible = false;
  var _cursorHidden = false;

  /// Lines printed before the plan context is known are held back so that
  /// the context block comes first.
  List<String>? _held;

  /// Holds permanent lines until [planContext] is called.
  void holdUntilContext() => _held ??= [];

  bool get _interactive => ui.caps.interactive;

  static const _clearLine = '\r\x1B[2K';

  String _stamp() {
    if (_interactive) return '';
    final t = _clock();
    String two(int v) => v.toString().padLeft(2, '0');
    return '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] ';
  }

  /// Prints a permanent line above the status line.
  void line(String text) {
    final safe = ui.safe(text);
    final held = _held;
    if (held != null) {
      held.add('${_stamp()}$safe');
      return;
    }
    _clearStatus();
    _write('${_stamp()}$safe\n');
    _drawStatus();
  }

  void _flushHeld() {
    final held = _held;
    _held = null;
    if (held == null || held.isEmpty) return;
    _clearStatus();
    _write('${held.join('\n')}\n');
    _drawStatus();
  }

  @override
  void planContext({
    required String project,
    required String? from,
    required String target,
    required List<String> platforms,
  }) {
    final held = _held;
    _held = null;
    _clearStatus();
    final context = ui.planContext(
      project: project,
      from: from == target ? null : from,
      target: target,
      platforms: platforms,
    );
    _write('${ui.safe(context.join('\n'))}\n\n');
    if (held != null && held.isNotEmpty) _write('${held.join('\n')}\n');
    _drawStatus();
  }

  void _clearStatus() {
    if (_statusVisible) {
      _write(_clearLine);
      _statusVisible = false;
    }
  }

  void _drawStatus() {
    if (!_interactive || _running.isEmpty) return;
    final spinner = ui.symbols.spinner[_frame % ui.symbols.spinner.length];
    final now = _clock();
    final items = _running.values.toList();
    final first = items.first;
    final labels = items.map((r) => r.label).join(', ');
    final elapsed = formatDuration(now.difference(first.started));
    final detail =
        first.detail == null ? '' : '  ${ui.style.dim(first.detail!)}';
    var text = '${Ui.margin}${' ' * first.indent}${ui.style.accent(spinner)} '
        '$labels$detail  ${ui.style.dim(elapsed)}';
    final max = ui.caps.width - 1;
    if (visibleLength(text) > max) {
      text = truncate(stripAnsi(text), max, ellipsis: ui.symbols.ellipsis);
    }
    if (!_cursorHidden) {
      _write('\x1B[?25l');
      _cursorHidden = true;
    }
    _write('$_clearLine$text');
    _statusVisible = true;
  }

  void _start(String id, String label, int indent) {
    _running[id] = _Running(label, _clock(), indent);
    if (_interactive) {
      _timer ??= Timer.periodic(_tick, (_) {
        _frame++;
        _clearStatus();
        _drawStatus();
      });
      _clearStatus();
      _drawStatus();
    }
  }

  void _stop(String id) {
    _running.remove(id);
    if (_running.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Stops the spinner and restores the cursor. Safe to call twice.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _running.clear();
    _flushHeld();
    _clearStatus();
    if (_cursorHidden) {
      _write('\x1B[?25h');
      _cursorHidden = false;
    }
  }

  String _label(String id, Map<String, Object?> args) =>
      ui.strings('stage.$id', args);

  @override
  void stageStarted(String id, {Map<String, Object?> args = const {}}) {
    if (id == 'verify') {
      final label = ui.style.bold(_label(id, args));
      final leader = (ui.caps.unicode ? '·' : '.') *
          (ui.contentWidth - visibleLength(label) - 4).clamp(0, 60);
      line(
        '${Ui.margin}${ui.mark(Mark.running)} $label ${ui.style.dim(leader)}',
      );
      return;
    }
    _start(id, _label(id, args), 0);
  }

  @override
  void stageProgress(String id, String detail) {
    final running = _running[id];
    if (running == null) return;
    running.detail = detail;
    if (_interactive) {
      _clearStatus();
      _drawStatus();
    }
  }

  @override
  void stageFinished(
    String id,
    StepStatus status, {
    String? labelKey,
    String? detailKey,
    Map<String, Object?> args = const {},
    Duration? duration,
  }) {
    _stop(id);
    if (id == 'verify') return;
    final label =
        labelKey == null ? _label(id, args) : ui.strings(labelKey, args);
    line(
      ui.row(
        Ui.markFor(status),
        label,
        detail: detailKey == null ? null : ui.strings(detailKey, args),
        duration: duration,
      ),
    );
  }

  @override
  void attemptStarted(int number, int max, List<String> changes) {
    final description =
        changes.isEmpty ? ui.strings('attempt.noChange') : changes.join(', ');
    final head = number == 1
        ? ui.strings('attempt.first', {'n': number, 'max': max})
        : ui.strings('attempt.retry', {'n': number, 'max': max});
    final kind = number == 1 ? Mark.info : Mark.retry;
    final prefix = '${Ui.margin}  ${ui.mark(kind)} ';
    final room = ui.contentWidth - 4 - visibleLength(head) - 2;
    final text = _interactive && visibleLength(description) > room
        ? truncate(description, room, ellipsis: ui.symbols.ellipsis)
        : description;
    line('$prefix${ui.style.accent(head)}  ${ui.style.dim(text)}');
  }

  String _stepLabel(String step) => ui.strings('step.$step');

  @override
  void stepStarted(String step) {
    if (!_interactive) {
      line('${Ui.margin}  ${ui.mark(Mark.running)} ${_stepLabel(step)}');
    }
    _start('step:$step', _stepLabel(step), 2);
  }

  @override
  void stepFinished(Evidence evidence) {
    _stop('step:${evidence.step}');
    line(
      ui.row(
        Ui.markFor(evidence.status),
        _stepLabel(evidence.step),
        detail: stepDetail(ui, evidence.detail),
        duration:
            evidence.status == StepStatus.skipped ? null : evidence.duration,
        indent: 2,
      ),
    );
  }
}
