@Tags(['golden'])
library;

import 'package:test/test.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ui/caps.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/live_progress.dart';
import 'package:upgrade_pilot/src/ui/plan_summary.dart';
import 'package:upgrade_pilot/src/ui/strings.dart';
import 'package:upgrade_pilot/src/ui/style.dart';

import '../support/builders.dart';
import '../support/fakes.dart';
import '../support/golden.dart';

/// The rendering modes required by the design: color TTY, TTY without
/// color, non-TTY, ASCII, at 80 and 120 columns.
final modes = <String, TerminalCaps>{
  'tty-color-80': const TerminalCaps(
    color: ColorLevel.truecolor,
    unicode: true,
    width: 80,
    interactive: true,
  ),
  'tty-color-120': const TerminalCaps(
    color: ColorLevel.ansi256,
    unicode: true,
    width: 120,
    interactive: true,
  ),
  'tty-nocolor-80': const TerminalCaps(
    color: ColorLevel.none,
    unicode: true,
    width: 80,
    interactive: true,
  ),
  'non-tty-80': const TerminalCaps(
    color: ColorLevel.none,
    unicode: true,
    width: 80,
    interactive: false,
  ),
  'ascii-80': TerminalCaps.plain,
};

Ui uiFor(TerminalCaps caps, {String lang = 'en'}) =>
    Ui(Style(caps), Strings.of(lang));

String render(Ui ui, List<String> lines) => '${ui.safe(lines.join('\n'))}\n';

/// Replays a realistic `plan` run through the live renderer.
String progress(Ui ui) {
  final out = StringBuffer();
  final live = LiveProgress(
    ui,
    out.write,
    clock: steppingClock(
      DateTime(2026, 10, 24, 11, 2),
      step: const Duration(seconds: 1),
    ),
    tick: const Duration(days: 1),
  )..holdUntilContext();
  Evidence ev(
    String step,
    StepStatus status,
    int attempt,
    int seconds, {
    String? detail,
  }) =>
      Evidence(
        step: step,
        command: 'flutter $step',
        status: status,
        duration: Duration(milliseconds: seconds * 100),
        attempt: attempt,
        detail: detail,
      );
  live
    ..stageStarted('inspect')
    ..stageFinished(
      'inspect',
      StepStatus.ok,
      detailKey: 'detail.project',
      args: {'name': 'my_app'},
      duration: const Duration(milliseconds: 400),
    )
    ..stageStarted('resolve', args: {'target': 'stable'})
    ..stageFinished(
      'resolve',
      StepStatus.ok,
      labelKey: 'stage.resolved',
      args: {'version': '3.44.9', 'channel': 'stable'},
      duration: const Duration(milliseconds: 300),
    )
    ..planContext(
      project: 'my_app',
      from: '3.24.5',
      target: '3.44.9',
      platforms: ['android', 'ios'],
    )
    ..stageStarted('prepare', args: {'version': '3.44.9'})
    ..stageFinished(
      'prepare',
      StepStatus.ok,
      detailKey: 'detail.sdk.cache',
      args: {'version': '3.44.9'},
      duration: const Duration(milliseconds: 1100),
    )
    ..stageStarted('sandbox')
    ..stageFinished(
      'sandbox',
      StepStatus.ok,
      detailKey: 'detail.filesSecrets',
      args: {'files': 128, 'secrets': 2},
      duration: const Duration(milliseconds: 2300),
    )
    ..stageStarted('verify')
    ..attemptStarted(1, 6, ['AGP 8.5.0 → 8.11.1', 'Gradle 8.7 → 8.14'])
    ..stepStarted('pub get')
    ..stepFinished(ev('pub get', StepStatus.ok, 1, 98))
    ..stepStarted('analyze')
    ..stepFinished(
      ev('analyze', StepStatus.warning, 1, 142, detail: '3 warnings'),
    )
    ..stepStarted('build apk')
    ..stepFinished(
      ev('build apk', StepStatus.failed, 1, 410, detail: 'UP-AND-0007'),
    )
    ..attemptStarted(2, 6, ['AGP 8.5.0 → 9.0.1', 'android.builtInKotlin=false'])
    ..stepStarted('pub get')
    ..stepFinished(ev('pub get', StepStatus.ok, 2, 51))
    ..stepStarted('build apk')
    ..stepFinished(ev('build apk', StepStatus.ok, 2, 526))
    ..stepFinished(
      ev(
        'build ios',
        StepStatus.skipped,
        2,
        0,
        detail: 'Xcode not available',
      ),
    )
    ..stepFinished(
      ev(
        'test',
        StepStatus.skipped,
        2,
        0,
        detail: 'not run (use --run-tests)',
      ),
    )
    ..stageFinished('verify', StepStatus.ok)
    ..dispose();
  return out.toString();
}

void main() {
  for (final MapEntry(key: mode, value: caps) in modes.entries) {
    group(mode, () {
      final ui = uiFor(caps);

      test('welcome', () {
        expectGolden(
          '$mode/welcome',
          render(ui, ui.welcome(version: '1.0.0', kbVersion: '2026.10.24')),
        );
      });

      test('plan summary (verified)', () {
        expectGolden(
          '$mode/summary-verified',
          render(ui, renderPlanSummary(ui, samplePlan())),
        );
      });

      test('plan summary (blocked)', () {
        expectGolden(
          '$mode/summary-blocked',
          render(
            ui,
            renderPlanSummary(ui, samplePlan(verdict: Verdict.blocked)),
          ),
        );
      });

      test('error', () {
        expectGolden(
          '$mode/error',
          render(
            ui,
            ui.error(
              title: 'The project changed since the plan',
              why: 'Files covered by the plan were edited after `plan` ran.',
              fix:
                  'Run `upgrade-pilot plan` again to verify the current state.',
              more: 'https://github.com/Andassa/upgrade-pilot#readme',
            ),
          ),
        );
      });

      if (!caps.interactive) {
        test('progress (stable, timestamped)', () {
          expectGolden('$mode/progress', progress(ui));
        });
      }
    });
  }

  test('French summary', () {
    final ui = uiFor(modes['tty-nocolor-80']!, lang: 'fr');
    expectGolden(
      'fr/summary-verified',
      render(ui, renderPlanSummary(ui, samplePlan())),
    );
  });

  test('verbose summary shows diffs', () {
    final ui = uiFor(modes['tty-color-80']!);
    expectGolden(
      'tty-color-80/summary-diffs',
      render(ui, renderPlanSummary(ui, samplePlan(), showDiffs: true)),
    );
  });

  test('interactive progress draws a spinner and restores the cursor', () {
    final ui = uiFor(modes['tty-color-80']!);
    final out = progress(ui);
    expect(out, contains('\x1B[?25l'));
    expect(out, endsWith('\x1B[?25h'));
    expect(out, contains('⠋'));
  });
}
