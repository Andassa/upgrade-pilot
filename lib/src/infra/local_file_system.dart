import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// [FileSystem] backed by `dart:io`. Never follows symbolic links when
/// listing.
final class LocalFileSystem implements FileSystem {
  LocalFileSystem({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  @override
  String get separator => Platform.pathSeparator;

  @override
  Future<bool> exists(String path) async =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  @override
  Future<bool> isDirectory(String path) async =>
      FileSystemEntity.isDirectorySync(path);

  @override
  Future<String?> readString(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return _guard(path, file.readAsString);
  }

  @override
  Future<List<int>?> readBytes(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return _guard(path, file.readAsBytes);
  }

  @override
  Future<void> writeString(String path, String content) =>
      writeBytes(path, utf8.encode(content));

  @override
  Future<void> writeBytes(String path, List<int> bytes) =>
      _guard(path, () async {
        final target = File(path);
        await target.parent.create(recursive: true);
        final temp = File('$path.tmp-${_random.nextInt(1 << 32)}');
        try {
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(path);
        } finally {
          if (temp.existsSync()) await temp.delete();
        }
      });

  @override
  Future<List<FsEntry>> list(String directory) => _guard(directory, () async {
        final dir = Directory(directory);
        if (!dir.existsSync()) return const <FsEntry>[];
        final entries = <FsEntry>[];
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is Link) {
            entries.add(
              FsEntry(
                path: entity.path,
                type: EntryType.link,
                linkTarget: entity.targetSync(),
              ),
            );
          } else if (entity is Directory) {
            entries.add(FsEntry(path: entity.path, type: EntryType.directory));
          } else if (entity is File) {
            entries.add(FsEntry(path: entity.path, type: EntryType.file));
          } else {
            entries.add(FsEntry(path: entity.path, type: EntryType.other));
          }
        }
        entries.sort((a, b) => a.path.compareTo(b.path));
        return entries;
      });

  @override
  Future<void> createDirectory(String path) =>
      _guard(path, () => Directory(path).create(recursive: true));

  @override
  Future<String> createPrivateTempDirectory(String parent, String prefix) =>
      _guard(parent, () async {
        await Directory(parent).create(recursive: true);
        final dir = await Directory(parent).createTemp(prefix);
        if (!Platform.isWindows) {
          // createTemp honours the umask on Linux (often 0755): enforce 0700
          // and fail closed if the mode cannot be set.
          final chmod = await Process.run('chmod', ['700', dir.path]);
          if (chmod.exitCode != 0 || dir.statSync().mode & 0x1ff != 0x1c0) {
            await dir.delete(recursive: true);
            throw FsException(
              'Cannot make the sandbox private',
              path: dir.path,
            );
          }
        }
        return dir.path;
      });

  @override
  Future<void> deleteRecursive(String path) => _guard(path, () async {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return;
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        } else if (type == FileSystemEntityType.link) {
          await Link(path).delete();
        } else {
          await File(path).delete();
        }
      });

  @override
  Future<void> rename(String from, String to) => _guard(from, () async {
        final type = FileSystemEntity.typeSync(from, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(from).rename(to);
        } else {
          await File(from).rename(to);
        }
      });

  @override
  Future<void> copyFiles(
    String sourceRoot,
    String targetRoot,
    List<String> relativeFiles,
  ) async {
    final byDirectory = <String, List<String>>{};
    for (final relative in relativeFiles) {
      byDirectory.putIfAbsent(p.dirname(relative), () => []).add(relative);
    }
    for (final MapEntry(key: dir, value: files) in byDirectory.entries) {
      final targetDir = p.join(targetRoot, dir);
      await createDirectory(targetDir);
      if (!await _cloneBatch(sourceRoot, targetDir, files)) {
        for (final relative in files) {
          await _guard(
            relative,
            () => File(
              p.join(sourceRoot, relative),
            ).copy(p.join(targetRoot, relative)),
          );
        }
      }
    }
  }

  /// Copy-on-write clone of a batch of files sharing [targetDir].
  Future<bool> _cloneBatch(
    String sourceRoot,
    String targetDir,
    List<String> files,
  ) async {
    final flag = Platform.isMacOS
        ? '-c'
        : Platform.isLinux
            ? '--reflink=auto'
            : null;
    if (flag == null) return false;
    const chunk = 200;
    for (var i = 0; i < files.length; i += chunk) {
      final batch = files.skip(i).take(chunk);
      final result = await Process.run('cp', [
        flag,
        '-p',
        for (final f in batch) p.join(sourceRoot, f),
        '$targetDir${Platform.pathSeparator}',
      ]);
      if (result.exitCode != 0) {
        if ('${result.stderr}'.contains('No space left')) {
          throw FsException('No space left on device', noSpace: true);
        }
        return false;
      }
    }
    return true;
  }

  @override
  Future<int?> freeBytes(String path) async {
    if (Platform.isWindows) return null;
    var existing = path;
    while (
        !Directory(existing).existsSync() && p.dirname(existing) != existing) {
      existing = p.dirname(existing);
    }
    final result = await Process.run('df', ['-Pk', existing]);
    if (result.exitCode != 0) return null;
    final lines = '${result.stdout}'.trim().split('\n');
    if (lines.length < 2) return null;
    final columns = lines.last.trim().split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final kb = int.tryParse(columns[3]);
    return kb == null ? null : kb * 1024;
  }

  @override
  Future<String> canonicalize(String path) =>
      _guard(path, () => File(path).resolveSymbolicLinks());

  @override
  Future<String?> sha256File(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return _guard(
      path,
      () async => (await sha256.bind(file.openRead()).first).toString(),
    );
  }

  Future<T> _guard<T>(String path, Future<T> Function() action) async {
    try {
      return await action();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      // ENOSPC on POSIX, ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL on Windows.
      final noSpace =
          code == 28 || (Platform.isWindows && (code == 112 || code == 39));
      throw FsException(
        noSpace ? 'No space left on device' : e.message,
        path: e.path ?? path,
        noSpace: noSpace,
      );
    }
  }
}
