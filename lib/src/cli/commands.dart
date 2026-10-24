import 'dart:async';
import 'dart:math' as math;

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade_pilot/src/application/apply_use_case.dart';
import 'package:upgrade_pilot/src/application/plan_use_case.dart';
import 'package:upgrade_pilot/src/cli/cli.dart';
import 'package:upgrade_pilot/src/cli/completion.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/exit_codes.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ports/ports.dart' hide Command;
import 'package:upgrade_pilot/src/ports/ports.dart' as ports show Command;
import 'package:upgrade_pilot/src/report/html_report.dart';
import 'package:upgrade_pilot/src/report/json_report.dart';
import 'package:upgrade_pilot/src/report/markdown_report.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/live_progress.dart';
import 'package:upgrade_pilot/src/ui/plan_summary.dart';
import 'package:upgrade_pilot/src/ui/text.dart';
import 'package:upgrade_pilot/src/version.dart';

List<Command<int>> buildCommands() => [
      DoctorCommand(),
      PlanCommand(),
      ReportCommand(),
      ApplyCommand(),
      ExplainCommand(),
      KbCommand(),
      CleanCommand(),
      CompletionCommand(),
    ];

/// Base class: output goes through the session console.
abstract class PilotCommand extends Command<int> {
  UpgradePilotRunner get pilot => runner! as UpgradePilotRunner;
  Session get session => pilot.session;
  Ui get ui => session.ui;

  @override
  void printUsage() => session.services.console.out('$usage\n');

  void addPathOption() => argParser.addOption(
        'path',
        abbr: 'p',
        defaultsTo: '.',
        valueHelp: 'dir',
        help: 'Flutter project directory.',
      );

  String projectPath() => p.absolute(
        session.services.host.currentDirectory,
        argResults!.option('path') ?? '.',
      );

  void header() {
    if (session.json || session.quiet) return;
    session.out([ui.header(packageVersion, command: name), '']);
  }
}

final class DoctorCommand extends PilotCommand {
  DoctorCommand() {
    argParser.addFlag(
      'offline',
      negatable: false,
      help: 'Skip the network check.',
    );
  }

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check Flutter, Dart, JDK, Android SDK, Xcode, git, network and disk.\n\n'
      'Examples:\n'
      '  upgrade-pilot doctor\n'
      '  upgrade-pilot doctor --offline --json';

  @override
  Future<int> run() async {
    header();
    final checks = await (await session.services.doctorUseCase()).run(
      offline: argResults!.flag('offline'),
    );
    final blocking = checks.any((c) => c.blocking);
    if (session.json) {
      session.printJson({
        'ok': !blocking,
        'checks': [
          for (final c in checks)
            {
              'name': c.name,
              'status': c.status.name,
              'detail': session.services.redactor.redact(c.detail),
              'required': c.required,
              'hint': c.hint,
            },
        ],
      });
    } else {
      final width = checks.fold(0, (w, c) => math.max(w, c.name.length));
      final lines = <String>[];
      for (final c in checks) {
        lines.add(
          '${Ui.margin}${ui.mark(Ui.markFor(c.status))} '
          '${padRight(c.name, width)}   '
          '${session.services.redactor.redact(c.detail)}',
        );
        if (c.hint != null && c.status != StepStatus.ok) {
          lines.add(
            ui.hint('${ui.symbols.arrow} ${c.hint}', indent: width + 5),
          );
        }
      }
      if (!session.quiet) {
        session.out([
          ...lines,
          '',
          ui.line(
            blocking ? Mark.fail : Mark.ok,
            ui.strings(blocking ? 'doctor.missing' : 'doctor.ok'),
          ),
        ]);
      }
    }
    return blocking ? ExitCodes.environment : ExitCodes.ok;
  }
}

Duration _parseDuration(String raw) {
  final match = RegExp(r'^(\d+)(s|m|h)?$').firstMatch(raw.trim());
  if (match == null) {
    throw UsageException('Invalid duration "$raw" (e.g. 90s, 20m, 1h).', '');
  }
  final value = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    's' => Duration(seconds: value),
    'h' => Duration(hours: value),
    _ => Duration(minutes: value),
  };
}

final class PlanCommand extends PilotCommand {
  PlanCommand() {
    addPathOption();
    argParser
      ..addOption(
        'to',
        defaultsTo: 'stable',
        valueHelp: 'version',
        help: 'Target: 3.44.9, 3.44, stable, beta or latest.',
      )
      ..addMultiOption(
        'platforms',
        allowed: const ['android', 'ios'],
        valueHelp: 'android,ios',
        help: 'Platforms to build (default: those the project has).',
      )
      ..addFlag('run-tests', negatable: false, help: 'Also run flutter test.')
      ..addOption(
        'jobs',
        abbr: 'j',
        defaultsTo: '1',
        valueHelp: 'N',
        help: 'Steps run in parallel after pub get.',
      )
      ..addOption(
        'max-attempts',
        defaultsTo: '6',
        valueHelp: 'N',
        help: 'Maximum verification attempts.',
      )
      ..addFlag(
        'keep-sandbox',
        negatable: false,
        help: 'Keep the sandbox for inspection.',
      )
      ..addOption(
        'timeout',
        defaultsTo: '20m',
        valueHelp: 'duration',
        help: 'Total time budget (e.g. 90s, 20m, 1h).',
      )
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Use cached release list, SDKs and pub.dev data only.',
      );
  }

  @override
  String get name => 'plan';

  @override
  String get description =>
      'Simulate the upgrade in a sandbox and produce a verified plan.\n'
      'Your project is not modified.\n\n'
      'Examples:\n'
      '  upgrade-pilot plan\n'
      '  upgrade-pilot plan --to 3.44 --platforms android\n'
      '  upgrade-pilot plan --to latest --run-tests --timeout 40m\n'
      '  upgrade-pilot plan --ci --json > plan.json';

  int _positive(String option) {
    final value = int.tryParse(argResults!.option(option) ?? '');
    if (value == null || value < 1) {
      throw UsageException('--$option must be a positive integer.', usage);
    }
    return value;
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    final platforms = args.multiOption('platforms');
    final request = PlanRequest(
      projectPath: projectPath(),
      target: args.option('to')!,
      platforms: platforms.isEmpty ? null : platforms.toSet(),
      runTests: args.flag('run-tests'),
      jobs: _positive('jobs'),
      maxAttempts: _positive('max-attempts'),
      keepSandbox: args.flag('keep-sandbox'),
      timeout: _parseDuration(args.option('timeout')!),
      offline: args.flag('offline'),
    );
    header();
    final console = session.services.console;
    final silent = session.json || session.quiet;
    final progress = LiveProgress(
      ui,
      silent ? (_) {} : console.out,
      clock: session.services.clock,
    )..holdUntilContext();
    final cancellation = CancellationToken();
    var interrupts = 0;
    final subscription = console.interrupts.listen((_) {
      interrupts++;
      cancellation.cancel();
      if (interrupts > 1) {
        progress.dispose();
        unawaited(session.services.sandboxes.disposeAll());
      }
    });
    final PlanResult result;
    try {
      final useCase = await session.services.planUseCase(
        offline: request.offline,
        observer: progress,
      );
      result = await useCase.execute(request, cancellation: cancellation);
    } finally {
      progress.dispose();
      await subscription.cancel();
      await session.services.sandboxes.disposeAll();
    }
    final plan = result.plan;
    if (session.json) {
      session.printJson(planReportJson(plan));
    } else if (session.quiet) {
      if (plan.verdict == Verdict.blocked) {
        session.err(['${ui.mark(Mark.fail)} ${ui.strings('panel.blocked')}']);
      }
    } else {
      session.out([
        ...renderPlanSummary(ui, plan, showDiffs: session.verbose),
        '',
        if (result.releaseListFromCache)
          '${Ui.margin}${ui.mark(Mark.warn)} ${ui.strings('plan.cachedList')}',
        if (result.sandboxPath != null)
          ui.line(
            Mark.info,
            ui.strings('plan.keptSandbox', {
              'path': session.services.redactor.redact(result.sandboxPath!),
            }),
          ),
        '${Ui.margin}${ui.style.dim(
          ui.strings('plan.duration', {
            'duration': formatDuration(plan.totalDuration),
          }),
        )}',
      ]);
    }
    return plan.verdict == Verdict.blocked ? ExitCodes.blocked : ExitCodes.ok;
  }
}

final class ReportCommand extends PilotCommand {
  ReportCommand() {
    addPathOption();
    argParser
      ..addOption(
        'format',
        abbr: 'f',
        allowed: const ['html', 'md', 'json'],
        defaultsTo: 'html',
        help: 'html writes a file; md and json print to stdout.',
      )
      ..addOption('output', abbr: 'o', valueHelp: 'file', help: 'Write here.')
      ..addFlag(
        'open',
        negatable: false,
        help: 'Open the HTML report in the default browser.',
      );
  }

  @override
  String get name => 'report';

  @override
  String get description =>
      'Render the last plan as HTML, Markdown or JSON.\n\n'
      'Examples:\n'
      '  upgrade-pilot report --open\n'
      '  upgrade-pilot report --format md > upgrade.md\n'
      '  upgrade-pilot report --format json -o plan.json';

  @override
  Future<int> run() async {
    final args = argResults!;
    final services = session.services;
    final root = projectPath();
    final plan = await services.store.load(root);
    if (plan == null) {
      throw ApplyRefusedException(ApplyRefusal.noPlan);
    }
    final format = args.option('format')!;
    final content = switch (format) {
      'md' => renderMarkdownReport(plan),
      'json' => renderJsonReport(plan),
      _ => renderHtmlReport(plan),
    };
    var output = args.option('output');
    if (output == null && format == 'html') {
      output = p.join(await services.store.directoryFor(root), 'report.html');
    }
    if (output == null) {
      services.console.out(content);
      return ExitCodes.ok;
    }
    final target = p.absolute(services.host.currentDirectory, output);
    await services.fs.writeString(target, content);
    if (session.json) {
      session.printJson({'written': target, 'format': format});
    } else if (!session.quiet) {
      session.out([
        ui.line(
          Mark.ok,
          ui.strings('report.written', {
            'path': services.redactor.redact(target),
          }),
        ),
      ]);
    }
    if (args.flag('open')) await _open(target);
    return ExitCodes.ok;
  }

  Future<void> _open(String path) async {
    final services = session.services;
    final command = switch (services.host.os) {
      'macos' => ('open', [path]),
      'windows' => ('explorer.exe', [path]),
      _ => ('xdg-open', [path]),
    };
    try {
      await services.runner.run(
        ports.Command(
          command.$1,
          command.$2,
          environment: {
            for (final key in const [
              'PATH',
              'HOME',
              'DISPLAY',
              'WAYLAND_DISPLAY',
              'XDG_RUNTIME_DIR',
              'SystemRoot',
            ])
              if (services.host.environment[key] case final value?) key: value,
          },
          timeout: const Duration(seconds: 20),
        ),
      );
    } on ProcessStartException {
      // The path is printed above; opening is a convenience.
    }
  }
}

final class ApplyCommand extends PilotCommand {
  ApplyCommand() {
    addPathOption();
    argParser
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Do not ask.')
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Allow uncommitted changes; on --revert, files edited since apply.',
      )
      ..addFlag(
        'revert',
        negatable: false,
        help: 'Restore the files saved by the last apply.',
      );
  }

  @override
  String get name => 'apply';

  @override
  String get description => 'Apply the last verified plan, after a backup.\n\n'
      'Examples:\n'
      '  upgrade-pilot apply\n'
      '  upgrade-pilot apply --yes\n'
      '  upgrade-pilot apply --revert';

  @override
  Future<int> run() async {
    final args = argResults!;
    final useCase = session.services.applyUseCase();
    final root = projectPath();
    final force = args.flag('force');
    if (args.flag('revert')) {
      final result = await useCase.revert(root, force: force);
      if (session.json) {
        session.printJson({'restored': result.restored});
      } else if (!session.quiet) {
        session.out([
          ui.line(
            Mark.ok,
            ui.strings('apply.reverted', {'count': result.restored.length}),
          ),
        ]);
      }
      return ExitCodes.ok;
    }
    final (plan, _) = await useCase.check(root, force: force);
    header();
    if (!session.json && !session.quiet) {
      session.out([
        ui.section(ui.strings('section.changes')),
        for (final c in plan.changes)
          ui.line(Mark.arrow, '${c.path}  ${ui.style.dim(c.summary)}'),
        '',
      ]);
    }
    if (!args.flag('yes')) {
      final console = session.services.console;
      if (!console.stdinIsTty || session.json) {
        throw ApplyRefusedException(ApplyRefusal.notConfirmed);
      }
      console.out(
        '${Ui.margin}${ui.strings('apply.confirm', {
              'changes':
                  ui.strings.plural('panel.changes', plan.changes.length),
              'project': plan.project.name,
            })}',
      );
      final answer = (console.readLine() ?? '').trim().toLowerCase();
      if (!const ['y', 'yes', 'o', 'oui'].contains(answer)) {
        session.out(['${Ui.margin}${ui.strings('apply.cancelled')}']);
        return ExitCodes.ok;
      }
    }
    final result = await useCase.apply(root, force: force);
    final backup = session.services.redactor.redact(result.backupDirectory);
    if (session.json) {
      session.printJson({
        'applied': [for (final c in result.applied) c.path],
        'backup': backup,
        'manualSteps': [for (final s in plan.manualSteps) s.toJson()],
      });
      return ExitCodes.ok;
    }
    if (session.quiet) return ExitCodes.ok;
    session.out([
      '',
      ui.line(
        Mark.ok,
        ui.strings('apply.done', {
          'changes': ui.strings.plural('panel.changes', result.applied.length),
        }),
      ),
      '${Ui.margin}  ${ui.style.dim(
        ui.strings('apply.backup', {
          'path': backup,
        }),
      )}',
      '${Ui.margin}  ${ui.style.dim(ui.strings('apply.revertHint'))}',
      if (plan.manualSteps.isNotEmpty) ...[
        '',
        ui.section(ui.strings('section.manual')),
        for (final s in plan.manualSteps) ...[
          '${Ui.margin}${ui.mark(Mark.info)} ${s.title}',
          if (s.command != null)
            '${Ui.margin}    ${ui.style.accent(s.command!)}',
        ],
      ],
    ]);
    return ExitCodes.ok;
  }
}

final class ExplainCommand extends PilotCommand {
  ExplainCommand() {
    addPathOption();
  }

  @override
  String get name => 'explain';

  @override
  String get invocation => 'upgrade-pilot explain <finding-id>';

  @override
  String get description =>
      'Explain a diagnosed problem: cause, evidence, fix and source.\n\n'
      'Examples:\n'
      '  upgrade-pilot explain UP-AND-0007\n'
      '  upgrade-pilot explain up-pub-0001 --json';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      throw UsageException('Expected exactly one finding id.', usage);
    }
    final explanation = await session.services
        .explainUseCase()
        .explain(projectPath(), rest.single);
    final finding = explanation.finding;
    final rule = explanation.rule;
    if (session.json) {
      session.printJson({
        'id': explanation.id,
        'finding': finding?.toJson(),
        if (rule != null)
          'rule': {
            'title': rule.title,
            'category': rule.category,
            'cause': rule.cause,
            'fix': rule.fix,
            'confidence': rule.confidence.name,
            'docsUrl': rule.docsUrl,
            'source': rule.source,
            'patternFrom': rule.patternFrom,
            'retrievedAt': rule.retrievedAt,
          },
      });
      return ExitCodes.ok;
    }
    header();
    final s = ui.strings;
    final lines = <String>[];
    if (finding != null) {
      lines.addAll(renderFinding(ui, finding));
    } else if (rule != null) {
      lines
        ..add(
          '${Ui.margin}${ui.mark(Mark.info)} ${ui.style.accent(rule.id)}  '
          '${ui.style.bold(rule.title)}',
        )
        ..addAll(
          ui.paragraph('${s('explain.cause')}: ${rule.cause}', indent: 4),
        )
        ..addAll(ui.paragraph('${s('explain.fix')}: ${rule.fix}', indent: 4))
        ..add('${Ui.margin}    ${ui.style.dim(s('explain.noEvidence'))}')
        ..add('${Ui.margin}    ${ui.style.accent(rule.docsUrl)}');
    }
    if (rule != null) {
      lines
        ..add('')
        ..addAll(
          ui.keyValues([
            (s('explain.confidence'), s('confidence.${rule.confidence.name}')),
            (s('explain.source'), '${rule.source} (${rule.retrievedAt})'),
          ]),
        );
    }
    session.out(lines);
    return ExitCodes.ok;
  }
}

final class KbCommand extends PilotCommand {
  KbCommand() {
    addSubcommand(KbUpdateCommand());
  }

  @override
  String get name => 'kb';

  @override
  String get description => 'Manage the compatibility knowledge base.';
}

final class KbUpdateCommand extends PilotCommand {
  @override
  String get name => 'update';

  @override
  String get description =>
      'Download the latest published knowledge base, verify its SHA-256 '
      'and install it if newer.\n\n'
      'Example:\n'
      '  upgrade-pilot kb update';

  @override
  Future<int> run() async {
    final result = await session.services.kbUpdateUseCase().update();
    if (session.json) {
      session.printJson({
        'updated': result.updated,
        'previous': result.previous,
        'current': result.current,
      });
    } else if (!session.quiet) {
      session.out([
        ui.line(
          Mark.ok,
          result.updated
              ? ui.strings('kb.updated', {
                  'from': result.previous,
                  'to': result.current,
                })
              : ui.strings('kb.current', {'version': result.current}),
        ),
      ]);
    }
    return ExitCodes.ok;
  }
}

final class CleanCommand extends PilotCommand {
  CleanCommand() {
    argParser.addFlag(
      'keep-sdks',
      negatable: false,
      help: 'Keep downloaded Flutter SDKs.',
    );
  }

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Delete caches, stored plans and leftover sandboxes. Backups made by '
      '`apply` are kept.\n\n'
      'Examples:\n'
      '  upgrade-pilot clean\n'
      '  upgrade-pilot clean --keep-sdks';

  @override
  Future<int> run() async {
    final removed = await session.services.cleanUseCase().clean(
          keepSdks: argResults!.flag('keep-sdks'),
        );
    final redactor = session.services.redactor;
    if (session.json) {
      session.printJson({
        'removed': [for (final r in removed) redactor.redact(r)],
      });
    } else if (!session.quiet) {
      session.out([
        for (final r in removed)
          '${Ui.margin}${ui.mark(Mark.ok)} ${redactor.redact(r)}',
        Ui.margin +
            (removed.isEmpty
                ? ui.strings('clean.nothing')
                : ui.strings.plural('clean.done', removed.length)),
      ]);
    }
    return ExitCodes.ok;
  }
}

final class CompletionCommand extends PilotCommand {
  @override
  String get name => 'completion';

  @override
  String get invocation => 'upgrade-pilot completion <bash|zsh|fish>';

  @override
  String get description => 'Print a shell completion script.\n\n'
      'Examples:\n'
      '  upgrade-pilot completion zsh > ~/.zfunc/_upgrade-pilot\n'
      '  upgrade-pilot completion bash >> ~/.bashrc\n'
      '  upgrade-pilot completion fish > ~/.config/fish/completions/upgrade-pilot.fish';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1 || !shells.contains(rest.single)) {
      throw UsageException('Expected one of: ${shells.join(', ')}.', usage);
    }
    session.services.console.out(completionScript(rest.single, pilot));
    return ExitCodes.ok;
  }
}
