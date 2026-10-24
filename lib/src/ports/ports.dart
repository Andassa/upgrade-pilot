import 'dart:async';

import 'package:meta/meta.dart';

/// Type of a file system entry. Links are never followed.
enum EntryType { file, directory, link, other }

@immutable
final class FsEntry {
  const FsEntry({required this.path, required this.type, this.linkTarget});

  /// Absolute path.
  final String path;
  final EntryType type;

  /// For links: the raw target as stored in the link.
  final String? linkTarget;
}

/// Thrown by [FileSystem] implementations. [noSpace] is set when the
/// device is full.
final class FsException implements Exception {
  FsException(this.message, {this.path, this.noSpace = false});

  final String message;
  final String? path;
  final bool noSpace;

  @override
  String toString() => path == null ? message : '$message ($path)';
}

/// All disk access goes through this interface.
abstract interface class FileSystem {
  String get separator;

  Future<bool> exists(String path);
  Future<bool> isDirectory(String path);

  /// Returns `null` when the file does not exist.
  Future<String?> readString(String path);
  Future<List<int>?> readBytes(String path);

  /// Writes atomically (temporary file + rename), creating parents.
  Future<void> writeString(String path, String content);
  Future<void> writeBytes(String path, List<int> bytes);

  /// Lists direct children without following links.
  Future<List<FsEntry>> list(String directory);
  Future<void> createDirectory(String path);

  /// Creates a new directory with an unpredictable name and mode 0700.
  Future<String> createPrivateTempDirectory(String parent, String prefix);
  Future<void> deleteRecursive(String path);
  Future<void> rename(String from, String to);

  /// Copies files from [sourceRoot] to [targetRoot], using copy-on-write
  /// clones when the platform supports them. [relativeFiles] are paths
  /// relative to both roots.
  Future<void> copyFiles(
    String sourceRoot,
    String targetRoot,
    List<String> relativeFiles,
  );

  /// Free bytes on the volume holding [path], or `null` if unknown.
  Future<int?> freeBytes(String path);

  /// Resolves `..`, `.` and links of an existing path.
  Future<String> canonicalize(String path);

  /// Streaming SHA-256 of a file, hex encoded; `null` if missing.
  Future<String?> sha256File(String path);
}

/// A command to run. Never interpreted by a shell.
@immutable
final class Command {
  const Command(
    this.executable,
    this.arguments, {
    this.workingDirectory,
    this.environment = const {},
    this.timeout,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// The complete environment of the child (no inheritance).
  final Map<String, String> environment;
  final Duration? timeout;

  String get display => [executable, ...arguments].join(' ');
}

@immutable
final class ProcessOutcome {
  const ProcessOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
    this.timedOut = false,
    this.cancelled = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final bool timedOut;
  final bool cancelled;

  bool get succeeded => exitCode == 0 && !timedOut && !cancelled;

  /// stdout and stderr combined, for diagnosis.
  String get output => stderr.isEmpty ? stdout : '$stdout\n$stderr';
}

/// Thrown when an executable cannot be started (not installed).
final class ProcessStartException implements Exception {
  ProcessStartException(this.executable, this.message);

  final String executable;
  final String message;

  @override
  String toString() => 'Cannot start $executable: $message';
}

/// Runs external processes.
abstract interface class ProcessRunner {
  /// Runs [command]. [onLine] receives output lines as they arrive.
  Future<ProcessOutcome> run(
    Command command, {
    void Function(String line)? onLine,
    CancellationToken? cancellation,
  });

  /// Absolute path of [executable] found on the `PATH`, or `null`.
  Future<String?> which(String executable);
}

@immutable
final class HttpReply {
  const HttpReply(this.statusCode, this.body);

  final int statusCode;
  final List<int> body;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// Thrown for network failures and refused (non allow-listed) URLs.
final class NetworkException implements Exception {
  NetworkException(this.message, {this.uri});

  final String message;
  final Uri? uri;

  @override
  String toString() => uri == null ? message : '$message ($uri)';
}

/// Network access. Implementations enforce an allow-list.
abstract interface class HttpPort {
  Future<HttpReply> get(Uri uri);

  /// Streams [uri] to [destination] and returns the number of bytes.
  Future<int> download(
    Uri uri,
    String destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  });
}

/// Returns the current time. Injected so that tests control time.
typedef Clock = DateTime Function();

/// Facts about the machine running the tool.
abstract interface class Host {
  /// `macos`, `linux` or `windows`.
  String get os;

  /// `arm64` or `x64`.
  String get architecture;
  Map<String, String> get environment;
  String get homeDirectory;

  /// Root of upgrade-pilot caches (SDKs, plans, metadata).
  String get cacheDirectory;
  String get temporaryDirectory;
  String get currentDirectory;
  int get processors;
}

/// The user's terminal.
abstract interface class Console {
  void out(String text);
  void err(String text);
  bool get stdoutIsTty;
  bool get stdinIsTty;

  /// Columns of the terminal, or `null` when unknown (not a TTY).
  int? get columns;

  /// Reads one line from stdin, or `null` at end of input.
  String? readLine();

  /// Emits once per Ctrl+C (SIGINT) or SIGTERM.
  Stream<void> get interrupts;
}

/// Cooperative cancellation (Ctrl+C).
final class CancellationToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Thrown when an operation stops because of a [CancellationToken].
final class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'Interrupted';
}
