import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:upgrade_pilot/src/ports/ports.dart';

/// [Console] backed by the process stdio and signals.
final class StdioConsole implements Console {
  @override
  void out(String text) => stdout.write(text);

  @override
  void err(String text) => stderr.write(text);

  @override
  bool get stdoutIsTty => stdout.hasTerminal;

  @override
  bool get stdinIsTty => stdin.hasTerminal;

  @override
  int? get columns => stdout.hasTerminal ? stdout.terminalColumns : null;

  @override
  String? readLine() => stdin.readLineSync(encoding: utf8);

  @override
  Stream<void> get interrupts {
    final signals = [
      ProcessSignal.sigint.watch(),
      if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
    ];
    final controller = StreamController<void>.broadcast();
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    controller
      ..onListen = () {
        for (final signal in signals) {
          subscriptions.add(signal.listen((_) => controller.add(null)));
        }
      }
      ..onCancel = () async {
        for (final s in subscriptions) {
          await s.cancel();
        }
        subscriptions.clear();
      };
    return controller.stream;
  }
}
