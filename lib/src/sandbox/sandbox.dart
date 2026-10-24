import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sandbox/copy_policy.dart';

/// A file whose content differs between the project and the sandbox.
@immutable
final class FileDelta {
  const FileDelta({
    required this.path,
    required this.before,
    required this.after,
  });

  /// Relative to the project root, `/` separated.
  final String path;

  /// `null` when the file is new.
  final String? before;
  final String after;
}

/// What the copy skipped, reported to the user.
@immutable
final class CopyReport {
  const CopyReport({
    required this.files,
    required this.secretsExcluded,
    required this.linksSkipped,
  });

  final int files;
  final int secretsExcluded;

  /// Relative paths of symbolic links that were not copied.
  final List<String> linksSkipped;
}

final class SandboxException implements Exception {
  SandboxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An isolated, private copy of a project. The original is never written.
final class Sandbox {
  Sandbox._({
    required FileSystem fs,
    required this.root,
    required this.copyRoot,
    required this.projectDirectory,
    required this.projectPrefix,
    required this.report,
    required Map<String, String> originals,
    required void Function(Sandbox) onDispose,
  })  : _fs = fs,
        _originals = originals,
        _onDispose = onDispose;

  final FileSystem _fs;

  /// Private temporary directory (mode 0700) holding the copy.
  final String root;

  /// Copy of the source copy root (the project, or its monorepo root).
  final String copyRoot;

  /// The Flutter project inside the sandbox.
  final String projectDirectory;

  /// Project path relative to [copyRoot] (`''` when identical), `/` based.
  final String projectPrefix;
  final CopyReport report;

  /// Original content of tracked files, keyed by copy-root relative path.
  final Map<String, String> _originals;
  final void Function(Sandbox) _onDispose;
  var _disposed = false;

  String _abs(String relative) => p.joinAll([copyRoot, ...relative.split('/')]);

  String _toProject(String copyRelative) => projectPrefix.isEmpty
      ? copyRelative
      : copyRelative.substring(projectPrefix.length + 1);

  String _toCopy(String projectRelative) => projectPrefix.isEmpty
      ? projectRelative
      : '$projectPrefix/$projectRelative';

  /// Original content of a project file, as copied.
  String? original(String projectRelative) =>
      _originals[_toCopy(projectRelative)];

  Future<String?> read(String projectRelative) =>
      _fs.readString(_abs(_toCopy(projectRelative)));

  Future<void> write(String projectRelative, String content) =>
      _fs.writeString(_abs(_toCopy(projectRelative)), content);

  /// Restores every tracked file to its original content and removes
  /// new files that would be part of a diff.
  Future<void> reset() async {
    for (final MapEntry(key: relative, value: content) in _originals.entries) {
      if (await _fs.readString(_abs(relative)) != content) {
        await _fs.writeString(_abs(relative), content);
      }
    }
    for (final relative in CopyPolicy.keptNewFiles) {
      final copyRelative = _toCopy(relative);
      if (!_originals.containsKey(copyRelative)) {
        await _fs.deleteRecursive(_abs(copyRelative));
      }
    }
  }

  /// Tracked files of the project that differ from the original.
  Future<List<FileDelta>> changes() async {
    final result = <FileDelta>[];
    for (final MapEntry(key: relative, value: before) in _originals.entries) {
      if (projectPrefix.isNotEmpty && !relative.startsWith('$projectPrefix/')) {
        continue;
      }
      final after = await _readText(_abs(relative));
      if (after != null && after != before) {
        result.add(
          FileDelta(path: _toProject(relative), before: before, after: after),
        );
      }
    }
    for (final relative in CopyPolicy.keptNewFiles) {
      if (_originals.containsKey(_toCopy(relative))) continue;
      final after = await _readText(_abs(_toCopy(relative)));
      if (after != null) {
        result.add(FileDelta(path: relative, before: null, after: after));
      }
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<String?> _readText(String path) async {
    final bytes = await _fs.readBytes(path);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Deletes the sandbox. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onDispose(this);
    await _fs.deleteRecursive(root);
  }
}

/// Creates sandboxes and remembers them so that an interruption can
/// delete them.
final class SandboxFactory {
  SandboxFactory(this._fs, this._host);

  final FileSystem _fs;
  final Host _host;
  final _active = <Sandbox>{};

  Iterable<Sandbox> get active => _active;

  /// Copies [copyRoot] (which contains [projectDirectory]) into a new
  /// private temporary directory.
  Future<Sandbox> create({
    required String projectDirectory,
    String? copyRoot,
  }) async {
    final source = await _fs.canonicalize(copyRoot ?? projectDirectory);
    final project = await _fs.canonicalize(projectDirectory);
    if (project != source && !p.isWithin(source, project)) {
      throw SandboxException('$project is not inside $source');
    }
    final prefix = project == source
        ? ''
        : p.relative(project, from: source).replaceAll(r'\', '/');

    final files = <String>[];
    final originals = <String, String>{};
    final links = <String>[];
    var secrets = 0;

    Future<void> walk(String dir) async {
      for (final entry in await _fs.list(dir)) {
        final relative =
            p.relative(entry.path, from: source).replaceAll(r'\', '/');
        if (relative.split('/').contains('..') || p.isAbsolute(relative)) {
          throw SandboxException(
            'Refusing path outside the project: $relative',
          );
        }
        final name = p.basename(entry.path);
        switch (entry.type) {
          case EntryType.directory:
            if (!CopyPolicy.excludedDirectories.contains(name)) {
              await walk(entry.path);
            }
          case EntryType.link:
            links.add(relative);
          case EntryType.file:
            if (CopyPolicy.isSecret(name)) {
              secrets++;
            } else if (!CopyPolicy.isMachineFile(name)) {
              files.add(relative);
              if (CopyPolicy.isTracked(relative)) {
                final bytes = await _fs.readBytes(entry.path);
                if (bytes != null &&
                    bytes.length <= CopyPolicy.maxTrackedBytes) {
                  try {
                    originals[relative] = utf8.decode(bytes);
                  } on FormatException {
                    // Binary content: copied but not diffed.
                  }
                }
              }
            }
          case EntryType.other:
            break;
        }
      }
    }

    await walk(source);
    final root = await _fs.createPrivateTempDirectory(
      _host.temporaryDirectory,
      'upgrade-pilot-',
    );
    final target = p.join(root, 'src');
    late final Sandbox sandbox;
    try {
      await _fs.createDirectory(target);
      await _fs.copyFiles(source, target, files);
      sandbox = Sandbox._(
        fs: _fs,
        root: root,
        copyRoot: target,
        projectDirectory:
            prefix.isEmpty ? target : p.joinAll([target, ...prefix.split('/')]),
        projectPrefix: prefix,
        report: CopyReport(
          files: files.length,
          secretsExcluded: secrets,
          linksSkipped: links,
        ),
        originals: originals,
        onDispose: _active.remove,
      );
    } on Object {
      await _fs.deleteRecursive(root);
      rethrow;
    }
    _active.add(sandbox);
    return sandbox;
  }

  /// Deletes every sandbox still alive (used on Ctrl+C).
  Future<void> disposeAll() async {
    for (final sandbox in _active.toList()) {
      await sandbox.dispose();
    }
  }
}
