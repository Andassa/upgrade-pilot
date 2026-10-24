import 'dart:math' as math;

import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/ui/components.dart';
import 'package:upgrade_pilot/src/ui/live_progress.dart';
import 'package:upgrade_pilot/src/ui/style.dart';
import 'package:upgrade_pilot/src/ui/text.dart';

/// The summary printed when `plan` ends.
List<String> renderPlanSummary(Ui ui, Plan plan, {bool showDiffs = false}) {
  final s = ui.strings;
  final style = ui.style;
  final lines = <String>[''];

  final (title, tone, kind) = switch (plan.verdict) {
    Verdict.verified => (s('panel.verified'), Palette.ok, Mark.ok),
    Verdict.verifiedWithWarnings => (
        s('panel.warnings'),
        Palette.warn,
        Mark.warn,
      ),
    Verdict.blocked => (s('panel.blocked'), Palette.error, Mark.fail),
  };
  final depsToUpdate = plan.dependencyUpdates.length;
  final dot = '  ${style.dim(ui.symbols.dot)}  ';
  final counts = [
    s.plural('panel.changes', plan.changes.length),
    s.plural('panel.deps', depsToUpdate),
    s.plural('panel.blocked', plan.blocked.length),
  ].join(dot);
  String status(String step, String label) {
    final evidence = plan.finalEvidence.where((e) => e.step == step);
    if (evidence.isEmpty) return '$label ${ui.mark(Mark.skip)}';
    return '$label ${ui.mark(Ui.markFor(evidence.first.status))}';
  }

  final builds = [
    status('build apk', s('panel.android')),
    status('build ios', s('panel.ios')),
    if (plan.finalEvidence.any((e) => e.step == 'test'))
      status('test', s('panel.tests'))
    else
      '${s('panel.tests')} ${style.dim(s('panel.notRun'))}',
  ].join('   ');
  lines
    ..addAll(ui.panel('${ui.mark(kind)} $title', [counts, builds], tone: tone))
    ..add('');

  if (plan.changes.isNotEmpty) {
    lines.add(
      plan.verdict == Verdict.blocked
          ? '${ui.section(s('section.changesTried'))}  '
              '${style.dim(s('section.changesTried.note'))}'
          : ui.section(s('section.changes')),
    );
    final width = math.min(
      plan.changes.fold(0, (w, c) => math.max(w, c.path.length)),
      48,
    );
    for (final change in plan.changes) {
      final path = change.path.length > width
          ? truncate(change.path, width, ellipsis: ui.symbols.ellipsis)
          : change.path;
      final summary =
          change.generated ? style.dim(change.summary) : change.summary;
      final row =
          '${Ui.margin}${ui.mark(Mark.arrow)} ${padRight(path, width)}  '
          '$summary';
      if (visibleLength(row) <= ui.contentWidth + Ui.margin.length) {
        lines.add(row);
      } else {
        lines
          ..add('${Ui.margin}${ui.mark(Mark.arrow)} $path')
          ..addAll(ui.paragraph(change.summary, indent: 4));
      }
      if (showDiffs && change.diff.isNotEmpty) {
        lines.addAll(_diff(ui, change.diff));
      }
    }
    lines.add('');
  }

  if (plan.blocked.isNotEmpty) {
    lines.add(ui.section(s('section.blocked')));
    for (final item in plan.blocked) {
      lines
        ..add('${Ui.margin}${ui.mark(Mark.fail)} ${style.bold(item.subject)}')
        ..addAll(ui.paragraph(item.reason, indent: 4));
      if (item.suggestion != null) {
        lines.add(
          '${Ui.margin}    ${ui.mark(Mark.arrow)} '
          '${s('blocked.suggestion', {'text': item.suggestion})}',
        );
      }
      if (item.findingId != null && item.findingId != Finding.unidentifiedId) {
        lines.add(
          '${Ui.margin}    ${style.dim(
            s('blocked.explain', {
              'id': item.findingId,
            }),
          )}',
        );
      }
    }
    lines.add('');
  }

  if (plan.verdict == Verdict.blocked) {
    final last = plan.attempts.isEmpty ? null : plan.attempts.last.findingId;
    final finding = last == null ? null : plan.finding(last);
    if (finding != null) {
      lines
        ..add(ui.section(s('section.diagnosis')))
        ..addAll(renderFinding(ui, finding))
        ..add('');
    }
  }

  lines.add(ui.section(s('section.notVerified')));
  for (final item in plan.notVerified) {
    lines.addAll(ui.bullet(Mark.skip, '${item.what}: ${item.reason}'));
  }
  lines.add('');

  if (plan.manualSteps.isNotEmpty && plan.verdict != Verdict.blocked) {
    lines.add(ui.section(s('section.manual')));
    for (final step in plan.manualSteps) {
      lines.add('${Ui.margin}${ui.mark(Mark.info)} ${step.title}');
      if (step.command != null) {
        lines.add('${Ui.margin}    ${style.accent(step.command!)}');
      }
    }
    lines.add('');
  }

  lines.add(
    ui.next([
      'upgrade-pilot report --open',
      if (plan.isApplicable) 'upgrade-pilot apply',
      if (plan.verdict == Verdict.blocked && plan.attempts.isNotEmpty)
        'upgrade-pilot explain ${plan.attempts.last.findingId ?? ''}'.trim(),
    ]),
  );
  return lines;
}

/// A finding with cause, fix, excerpt and documentation link.
List<String> renderFinding(Ui ui, Finding finding) {
  final s = ui.strings;
  final style = ui.style;
  final head = finding.identified
      ? '${style.accent(finding.id)}  ${style.bold(finding.title)}'
      : style.bold(finding.title);
  final lines = [
    ui.line(Mark.fail, '$head  ${style.dim('(${finding.step})')}'),
    ...ui.paragraph('${s('explain.cause')}: ${finding.cause}', indent: 4),
    ...ui.paragraph('${s('explain.fix')}: ${finding.fix}', indent: 4),
  ];
  if (finding.excerpt.isNotEmpty) {
    final bar = style.dim(ui.symbols.box.vertical);
    final width = ui.contentWidth - 6;
    for (final line in finding.excerpt.split('\n').take(12)) {
      for (final part in wrap(line, width)) {
        lines.add('${Ui.margin}    $bar ${style.dim(part)}');
      }
    }
  }
  if (finding.docsUrl != null) {
    lines.add('${Ui.margin}    ${style.accent(finding.docsUrl!)}');
  }
  return lines;
}

List<String> _diff(Ui ui, String diff) => [
      for (final line in diff.trimRight().split('\n'))
        '${Ui.margin}    ${switch (line) {
          _ when line.startsWith('+++') || line.startsWith('---') =>
            ui.style.dim(line),
          _ when line.startsWith('+') => ui.style.ok(line),
          _ when line.startsWith('-') => ui.style.error(line),
          _ when line.startsWith('@@') => ui.style.accent(line),
          _ => ui.style.dim(line),
        }}',
    ];

/// Evidence rows of a plan, grouped by attempt (used by `report`).
List<String> renderEvidence(Ui ui, Plan plan) => [
      for (final e in plan.evidence)
        ui.row(
          Ui.markFor(e.status),
          '#${e.attempt} ${ui.strings('step.${e.step}')}',
          detail: stepDetail(ui, e.detail),
          duration: e.status == StepStatus.skipped ? null : e.duration,
        ),
    ];
