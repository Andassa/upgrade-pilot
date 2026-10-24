import 'dart:async';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:upgrade_pilot/src/cli/commands.dart';
import 'package:upgrade_pilot/src/cli/errors.dart';
import 'package:upgrade_pilot/src/cli/services.dart';
import 'package:upgrade_pilot/src/domain/exit_codes.dart';
import 'package:upgrade_pilot/src/ui/caps.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';
import 'package:upgrade_pilot/src/ui/style.dart';
import 'package:upgrade_pilot/src/version.dart';

/// Per-invocation state built from the global flags.
final class Session {
  Session({
    required this.services,
    required this.ui,
    required this.json,
    required this.quiet,
    required this.verbose,
    required this.ci,
  });

  final Services services;
  final Ui ui;
  final bool json;
  final bool quiet;
  final bool verbose;
  final bool ci;

  Strings get strings => ui.strings;

  void out(Iterable<String> lines) {
    final text = ui.safe(lines.join('\n'));
    services.console.out(text.isEmpty ? '\n' : '$text\n');
  }

  void err(Iterable<String> lines) =>
      services.console.err('${ui.safe(lines.join('\n'))}\n');

  void printJson(Object? value) => services.console.out(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      );
}

const _description =
    'Rehearse a Flutter upgrade in an isolated sandbox and get a verified '
    'plan: the exact SDK, pub and Android/iOS toolchain changes, proven by '
    'a real build.';

const _footer = '''

Exit codes:
  0   plan verified (or command succeeded)
  1   invalid usage
  2   plan has unresolved blocking problems
  3   incomplete environment (Flutter, disk, network...)
  4   interrupted (Ctrl+C)
  70  internal error

Docs: https://github.com/Andassa/upgrade-pilot#readme''';

final class UpgradePilotRunner extends CommandRunner<int> {
  UpgradePilotRunner(this.services)
      : super('upgrade-pilot', _description, usageLineLength: 80) {
    argParser
      ..addFlag('version', negatable: false, help: 'Print the version.')
      ..addFlag(
        'json',
        negatable: false,
        help: 'Machine-readable output (stable, versioned JSON).',
      )
      ..addFlag(
        'color',
        defaultsTo: true,
        help: 'Colored output. Also disabled by NO_COLOR or a non-TTY.',
      )
      ..addFlag(
        'ascii',
        negatable: false,
        help: 'ASCII symbols only (for terminals without Unicode).',
      )
      ..addFlag('quiet', abbr: 'q', negatable: false, help: 'Errors only.')
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Details, diffs and stack traces.',
      )
      ..addFlag(
        'ci',
        negatable: false,
        help: 'CI mode: no animation, timestamped and stable output.',
      )
      ..addOption(
        'lang',
        allowed: Strings.supported,
        help: 'Language of messages (default: UPGRADE_PILOT_LANG, else en).',
      );
    buildCommands().forEach(addCommand);
  }

  final Services services;
  Session? _session;

  Session get session => _session ?? _defaultSession();

  @override
  String get usageFooter => _footer;

  @override
  void printUsage() => services.console.out('$usage\n');

  Session _defaultSession() => _session = _buildSession(
        json: false,
        quiet: false,
        verbose: false,
        ci: false,
        color: true,
        ascii: false,
        lang: null,
      );

  Session _buildSession({
    required bool json,
    required bool quiet,
    required bool verbose,
    required bool ci,
    required bool color,
    required bool ascii,
    required String? lang,
  }) {
    final env = services.host.environment;
    final caps = TerminalCaps.detect(
      environment: env,
      stdoutIsTty: services.console.stdoutIsTty,
      columns: services.console.columns,
      isWindows: services.host.os == 'windows',
      noColorFlag: !color || json,
      ciFlag: ci,
      asciiFlag: ascii,
    );
    final strings = Strings.of(lang ?? env['UPGRADE_PILOT_LANG']);
    return Session(
      services: services,
      ui: Ui(Style(caps), strings),
      json: json,
      quiet: quiet,
      verbose: verbose,
      ci: ci || !caps.interactive,
    );
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    _session = _buildSession(
      json: topLevelResults.flag('json'),
      quiet: topLevelResults.flag('quiet'),
      verbose: topLevelResults.flag('verbose'),
      ci: topLevelResults.flag('ci'),
      color: topLevelResults.flag('color'),
      ascii: topLevelResults.flag('ascii'),
      lang: topLevelResults.option('lang'),
    );
    if (topLevelResults.flag('version')) {
      if (session.json) {
        session.printJson({'version': packageVersion});
      } else {
        session.out(['upgrade-pilot $packageVersion']);
      }
      return ExitCodes.ok;
    }
    if (topLevelResults.command == null && topLevelResults.rest.isNotEmpty) {
      throw UsageException(
        'Could not find a command named "${topLevelResults.rest.first}".',
        usage,
      );
    }
    if (topLevelResults.command == null && !topLevelResults.flag('help')) {
      final ui = session.ui;
      if (ui.caps.interactive && !session.json) {
        final kb = await services.knowledgeBase();
        session
            .out(ui.welcome(version: packageVersion, kbVersion: kb.kbVersion));
      } else {
        printUsage();
      }
      return ExitCodes.ok;
    }
    return super.runCommand(topLevelResults);
  }
}

/// Runs the CLI and returns the process exit code. Never throws.
Future<int> runCli(List<String> arguments, Services services) async {
  final runner = UpgradePilotRunner(services);
  try {
    return await runner.run(arguments) ?? ExitCodes.ok;
  } on Object catch (error, stack) {
    final session = runner.session;
    final described = describeError(
      error,
      session.strings,
      services.redactor,
    );
    if (session.json) {
      session.printJson({
        'error': {
          'code': described.code,
          'title': described.title,
          'why': described.why,
          'fix': described.fix,
        },
      });
    } else {
      final lines = [
        '',
        ...session.ui.error(
          title: described.title,
          why: described.why,
          fix: described.fix,
          more: described.more,
        ),
        '',
      ];
      if (error is UsageException && !session.quiet) {
        lines
          ..addAll(
            error.usage
                .split('\n')
                .map((l) => '${Ui.margin}${session.ui.style.dim(l)}'),
          )
          ..add('');
      }
      if (described.internal && session.verbose) {
        lines.addAll(services.redactor.redact('$stack').split('\n'));
      }
      session.err(lines);
    }
    return described.code;
  }
}
