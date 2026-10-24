import 'package:args/command_runner.dart';
import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/analysis/project_inspector.dart';
import 'package:upgrade_pilot/src/analysis/pubspec_parser.dart';
import 'package:upgrade_pilot/src/application/apply_use_case.dart';
import 'package:upgrade_pilot/src/application/maintenance_use_cases.dart';
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/exit_codes.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sandbox/sandbox.dart';
import 'package:upgrade_pilot/src/sdk/release_catalog.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';
import 'package:upgrade_pilot/src/ui/text.dart';

const docsUrl = 'https://github.com/Andassa/upgrade-pilot#readme';

/// An error ready to print in the fixed format.
@immutable
final class CliError {
  const CliError({
    required this.code,
    required this.title,
    this.why,
    this.fix,
    this.more,
    this.internal = false,
  });

  final int code;
  final String title;
  final String? why;
  final String? fix;
  final String? more;

  /// Unexpected: the stack trace is shown with --verbose.
  final bool internal;
}

/// Maps any exception to an exit code and a human message.
CliError describeError(Object error, Strings s, Redactor redactor) {
  String r(String text) => redactor.redact(text);
  CliError make(
    String key,
    int code, {
    String? why,
    Map<String, Object?> args = const {},
  }) =>
      CliError(
        code: code,
        title: s('error.$key.title', args),
        why:
            why ?? (s.has('error.$key.why') ? s('error.$key.why', args) : null),
        fix: s.has('error.$key.fix') ? s('error.$key.fix', args) : null,
        more: docsUrl,
      );

  return switch (error) {
    UsageException(:final message) =>
      make('usage', ExitCodes.usage, why: message),
    NotAFlutterProjectException(:final path, :final reason) => make(
        'notFlutter',
        ExitCodes.usage,
        why: r('$path: $reason'),
      ),
    ManifestException(:final file, :final message) => make(
        'manifest',
        ExitCodes.usage,
        why: '$file: $message',
      ),
    ReleaseCatalogException(:final offline, :final message) when offline =>
      make('offline', ExitCodes.environment, why: message),
    ReleaseCatalogException(:final message) => make(
        'release',
        ExitCodes.usage,
        why: message,
      ),
    NetworkException(:final message, :final uri) => make(
        'network',
        ExitCodes.environment,
        why: uri == null ? message : '$message ($uri)',
      ),
    InsufficientDiskException(:final required, :final available) => make(
        'disk',
        ExitCodes.environment,
        args: {
          'required': formatBytes(required),
          'available': formatBytes(available),
        },
      ),
    FsException(noSpace: true, :final message) => make(
        'disk',
        ExitCodes.environment,
        why: message,
      ),
    SdkException(:final message) =>
      make('sdk', ExitCodes.environment, why: r(message)),
    ProcessStartException(:final executable, :final message) => make(
        'sdk',
        ExitCodes.environment,
        why: r('$executable: $message'),
      ),
    ApplyRefusedException(:final reason, :final detail) => switch (reason) {
        ApplyRefusal.noPlan => make('noPlan', ExitCodes.usage),
        ApplyRefusal.blockedPlan => make('blockedPlan', ExitCodes.blocked),
        ApplyRefusal.emptyPlan => make('emptyPlan', ExitCodes.ok),
        ApplyRefusal.projectChanged => make('changed', ExitCodes.blocked),
        ApplyRefusal.dirtyWorktree => make('dirty', ExitCodes.usage),
        ApplyRefusal.fileConflict => make(
            'conflict',
            ExitCodes.blocked,
            args: {'path': detail ?? '?'},
          ),
        ApplyRefusal.noBackup => make('noBackup', ExitCodes.usage),
        ApplyRefusal.notConfirmed => make('notConfirmed', ExitCodes.usage),
      },
    UnknownFindingException(:final id) => make(
        'unknownFinding',
        ExitCodes.usage,
        args: {'id': id},
      ),
    KnowledgeBaseException(:final message) => make(
        'kb',
        ExitCodes.environment,
        why: message,
      ),
    RulesException(:final message) => CliError(
        code: ExitCodes.internal,
        title: s('error.internal.title'),
        why: message,
        fix: s('error.internal.fix'),
        internal: true,
      ),
    PlanStoreException(:final message) =>
      make('plan', ExitCodes.usage, why: message),
    SandboxException(:final message) =>
      make('notFlutter', ExitCodes.usage, why: r(message)),
    CancelledException() => make('interrupted', ExitCodes.interrupted),
    _ => CliError(
        code: ExitCodes.internal,
        title: s('error.internal.title'),
        why: r('$error'),
        fix: s('error.internal.fix'),
        more: 'https://github.com/Andassa/upgrade-pilot/issues',
        internal: true,
      ),
  };
}
