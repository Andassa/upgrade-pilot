import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// In-memory [FileSystem] with POSIX paths.
class MemoryFileSystem implements FileSystem {
  final files = <String, List<int>>{};
  final directories = <String>{'/'};
  final links = <String, String>{};
  int? free = 100 * 1024 * 1024 * 1024;
  var _temp = 0;

  /// When set, writes fail as if the disk were full.
  bool diskFull = false;

  /// POSIX paths; Windows separators produced by `package:path` on a
  /// Windows host are folded so that the same tests run everywhere.
  String _n(String path) => p.posix.normalize(path.replaceAll(r'\', '/'));

  void _mkdirs(String dir) {
    var current = _n(dir);
    while (true) {
      directories.add(current);
      final parent = p.posix.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  void addFile(String path, String content) {
    files[_n(path)] = utf8.encode(content);
    _mkdirs(p.posix.dirname(_n(path)));
  }

  void addTree(String root, Map<String, String> tree) {
    for (final MapEntry(:key, :value) in tree.entries) {
      addFile(p.posix.join(root, key), value);
    }
  }

  String? text(String path) {
    final bytes = files[_n(path)];
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  String get separator => '/';

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(_n(path)) ||
      directories.contains(_n(path)) ||
      links.containsKey(_n(path));

  @override
  Future<bool> isDirectory(String path) async => directories.contains(_n(path));

  @override
  Future<String?> readString(String path) async => text(path);

  @override
  Future<List<int>?> readBytes(String path) async => files[_n(path)];

  @override
  Future<void> writeString(String path, String content) =>
      writeBytes(path, utf8.encode(content));

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (diskFull) throw FsException('No space left on device', noSpace: true);
    files[_n(path)] = List.of(bytes);
    _mkdirs(p.posix.dirname(_n(path)));
  }

  @override
  Future<List<FsEntry>> list(String directory) async {
    final dir = _n(directory);
    final children = <String, EntryType>{};
    void consider(String path, EntryType type) {
      if (p.posix.dirname(path) == dir && path != dir) children[path] = type;
    }

    for (final f in files.keys) {
      consider(f, EntryType.file);
    }
    for (final d in directories) {
      consider(d, EntryType.directory);
    }
    for (final l in links.keys) {
      consider(l, EntryType.link);
    }
    final sorted = children.keys.toList()..sort();
    return [
      for (final path in sorted)
        FsEntry(path: path, type: children[path]!, linkTarget: links[path]),
    ];
  }

  @override
  Future<void> createDirectory(String path) async => _mkdirs(path);

  @override
  Future<String> createPrivateTempDirectory(
    String parent,
    String prefix,
  ) async {
    if (diskFull) throw FsException('No space left on device', noSpace: true);
    final path = p.posix.join(_n(parent), '$prefix${_temp++}x');
    _mkdirs(path);
    return path;
  }

  @override
  Future<void> deleteRecursive(String path) async {
    final target = _n(path);
    bool inside(String x) => x == target || p.posix.isWithin(target, x);
    files.removeWhere((k, _) => inside(k));
    directories.removeWhere(inside);
    links.removeWhere((k, _) => inside(k));
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = _n(from);
    final target = _n(to);
    String move(String x) => x == source
        ? target
        : p.posix.join(target, p.posix.relative(x, from: source));
    bool inside(String x) => x == source || p.posix.isWithin(source, x);
    for (final key in files.keys.where(inside).toList()) {
      files[move(key)] = files.remove(key)!;
    }
    for (final d in directories.where(inside).toList()) {
      directories
        ..remove(d)
        ..add(move(d));
    }
    _mkdirs(p.posix.dirname(target));
  }

  @override
  Future<void> copyFiles(
    String sourceRoot,
    String targetRoot,
    List<String> relativeFiles,
  ) async {
    for (final relative in relativeFiles) {
      final bytes = files[_n(p.posix.join(sourceRoot, relative))];
      if (bytes == null) throw FsException('missing', path: relative);
      await writeBytes(p.posix.join(targetRoot, relative), bytes);
    }
  }

  @override
  Future<int?> freeBytes(String path) async => free;

  @override
  Future<String> canonicalize(String path) async => _n(path);

  @override
  Future<String?> sha256File(String path) async {
    final bytes = files[_n(path)];
    return bytes == null ? null : sha256.convert(bytes).toString();
  }
}

/// A scripted response of [FakeProcessRunner].
typedef ProcessScript = FutureOr<ProcessOutcome> Function(Command command);

ProcessOutcome outcome({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
  Duration duration = const Duration(seconds: 1),
}) =>
    ProcessOutcome(
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      duration: duration,
    );

/// Records commands and answers with scripts matched on the arguments.
final class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.onPath = const {}});

  final Map<String, String> onPath;
  final commands = <Command>[];
  final _scripts = <(bool Function(Command), ProcessScript)>[];

  /// Answers commands whose display contains [fragment].
  void on(String fragment, ProcessScript script) => _scripts.add(
        (
          (c) => c.display.replaceAll(r'\', '/').contains(fragment),
          script,
        ),
      );

  @override
  Future<ProcessOutcome> run(
    Command command, {
    void Function(String line)? onLine,
    CancellationToken? cancellation,
  }) async {
    commands.add(command);
    for (final (matches, script) in _scripts.reversed) {
      if (matches(command)) {
        final result = await script(command);
        if (onLine != null) result.stdout.split('\n').forEach(onLine);
        return result;
      }
    }
    throw ProcessStartException(command.executable, 'not scripted');
  }

  @override
  Future<String?> which(String executable) async => onPath[executable];
}

class FakeHttp implements HttpPort {
  final responses = <String, HttpReply>{};
  final requested = <Uri>[];
  bool offline = false;

  void json(String url, Object body, {int status = 200}) =>
      responses[url] = HttpReply(status, utf8.encode(jsonEncode(body)));

  void text(String url, String body, {int status = 200}) =>
      responses[url] = HttpReply(status, utf8.encode(body));

  @override
  Future<HttpReply> get(Uri uri) async {
    requested.add(uri);
    if (offline) throw NetworkException('offline', uri: uri);
    return responses['$uri'] ?? const HttpReply(404, []);
  }

  @override
  Future<int> download(
    Uri uri,
    String destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    throw NetworkException('download not scripted', uri: uri);
  }
}

final class FakeHost implements Host {
  FakeHost({
    this.os = 'linux',
    this.architecture = 'x64',
    this.homeDirectory = '/home/dev',
    this.cacheDirectory = '/home/dev/.cache/upgrade-pilot',
    this.temporaryDirectory = '/tmp',
    this.currentDirectory = '/work',
    Map<String, String>? environment,
  }) : environment =
            environment ?? {'PATH': '/usr/bin:/bin', 'HOME': '/home/dev'};

  @override
  final String os;
  @override
  final String architecture;
  @override
  final Map<String, String> environment;
  @override
  final String homeDirectory;
  @override
  final String cacheDirectory;
  @override
  final String temporaryDirectory;
  @override
  final String currentDirectory;
  @override
  int get processors => 8;
}

final class FakeConsole implements Console {
  FakeConsole({
    this.stdoutIsTty = false,
    this.stdinIsTty = false,
    this.columns,
    List<String>? input,
  }) : _input = input ?? [];

  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final List<String> _input;
  final _interrupts = StreamController<void>.broadcast();

  @override
  final bool stdoutIsTty;
  @override
  final bool stdinIsTty;
  @override
  final int? columns;

  String get output => stdoutBuffer.toString();
  String get errors => stderrBuffer.toString();

  void interrupt() => _interrupts.add(null);

  @override
  void out(String text) => stdoutBuffer.write(text);

  @override
  void err(String text) => stderrBuffer.write(text);

  @override
  String? readLine() => _input.isEmpty ? null : _input.removeAt(0);

  @override
  Stream<void> get interrupts => _interrupts.stream;
}

/// A clock that advances by [step] at every call.
DateTime Function() steppingClock(
  DateTime start, {
  Duration step = const Duration(milliseconds: 100),
}) {
  var now = start;
  return () {
    final current = now;
    now = now.add(step);
    return current;
  };
}
