import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// [ProcessRunner] backed by `dart:io`. Never uses a shell, never inherits
/// the parent environment, and stops children on timeout or cancellation.
final class LocalProcessRunner implements ProcessRunner {
  LocalProcessRunner({Map<String, String>? environment})
      : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  /// Output kept in memory per stream; older output is dropped.
  static const int _maxBuffered = 2 * 1024 * 1024;
  static const _killGrace = Duration(seconds: 5);

  @override
  Future<ProcessOutcome> run(
    Command command, {
    void Function(String line)? onLine,
    CancellationToken? cancellation,
  }) async {
    final watch = Stopwatch()..start();
    final Process process;
    try {
      process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw ProcessStartException(command.executable, e.message);
    }
    final stdoutBuffer = _TailBuffer(_maxBuffered);
    final stderrBuffer = _TailBuffer(_maxBuffered);
    Future<void> listen(Stream<List<int>> stream, _TailBuffer buffer) => stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) {
          buffer.add(line);
          onLine?.call(line);
        });

    final streams = [
      listen(process.stdout, stdoutBuffer),
      listen(process.stderr, stderrBuffer),
    ];

    var exited = false;
    var timedOut = false;
    var cancelled = false;
    void stop() {
      if (exited) return;
      process.kill();
      Timer(_killGrace, () {
        if (!exited) process.kill(ProcessSignal.sigkill);
      });
    }

    Timer? timer;
    if (command.timeout != null) {
      timer = Timer(command.timeout!, () {
        timedOut = true;
        stop();
      });
    }
    unawaited(
      cancellation?.whenCancelled.then((_) {
        cancelled = true;
        stop();
      }),
    );
    final exitCode = await process.exitCode;
    exited = true;
    timer?.cancel();
    // Grandchildren (e.g. Gradle daemons) may keep the pipes open.
    await Future.wait(streams).timeout(
      _killGrace,
      onTimeout: () => const <void>[],
    );
    return ProcessOutcome(
      exitCode: exitCode,
      stdout: stdoutBuffer.text,
      stderr: stderrBuffer.text,
      duration: watch.elapsed,
      timedOut: timedOut,
      cancelled: cancelled,
    );
  }

  @override
  Future<String?> which(String executable) async {
    if (p.isAbsolute(executable)) {
      return File(executable).existsSync() ? executable : null;
    }
    final path = _environment['PATH'] ?? _environment['Path'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final extensions = Platform.isWindows
        ? (_environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
            .split(';')
            .map((e) => e.toLowerCase())
            .toList()
        : const [''];
    for (final dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final ext in extensions) {
        final candidate = p.join(dir, '$executable$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}

final class _TailBuffer {
  _TailBuffer(this._limit);

  final int _limit;
  final _lines = <String>[];
  var _size = 0;

  void add(String line) {
    _lines.add(line);
    _size += line.length + 1;
    while (_size > _limit && _lines.length > 1) {
      _size -= _lines.removeAt(0).length + 1;
    }
  }

  String get text => _lines.join('\n');
}
