import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

/// Shared wording of the Markdown and HTML reports.
abstract final class ReportText {
  static String verdict(Verdict v) => switch (v) {
        Verdict.verified => 'Verified plan',
        Verdict.verifiedWithWarnings => 'Verified plan, with warnings',
        Verdict.blocked => 'Plan blocked',
      };

  static String verdictSymbol(Verdict v) => switch (v) {
        Verdict.verified => '✔',
        Verdict.verifiedWithWarnings => '▲',
        Verdict.blocked => '✖',
      };

  static String symbol(StepStatus status) => switch (status) {
        StepStatus.ok => '✔',
        StepStatus.warning => '▲',
        StepStatus.failed => '✖',
        StepStatus.skipped => '─',
      };

  static String statusWord(StepStatus status) => switch (status) {
        StepStatus.ok => 'passed',
        StepStatus.warning => 'passed with warnings',
        StepStatus.failed => 'failed',
        StepStatus.skipped => 'not run',
      };

  static String duration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  static String platformStatus(Plan plan, String step) {
    final e = plan.finalEvidence.where((x) => x.step == step);
    if (e.isEmpty) return '─ not verified';
    return '${symbol(e.first.status)} ${statusWord(e.first.status)}';
  }

  static String fromTo(Plan plan) {
    final dart = plan.target.dartVersion;
    final dartText = dart == null ? '' : ', Dart ${shortVersion(dart)}';
    final target = '${shortVersion(plan.target.version)} '
        '(${plan.target.channel}$dartText)';
    final from = plan.project.flutterVersion;
    return from == null ? target : '$from → $target';
  }

  static const limits =
      'upgrade-pilot proves that the project resolves, analyzes and builds '
      'with the target toolchain in an isolated copy. A successful build '
      'does not prove that the app behaves the same at runtime: run the app '
      'and its tests after applying the plan.';
}
