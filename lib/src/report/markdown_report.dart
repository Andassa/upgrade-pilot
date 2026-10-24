import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/report/report_text.dart';

String _cell(String? text) =>
    (text ?? '').replaceAll('|', r'\|').replaceAll('\n', ' ');

String _fence(String text) {
  var length = 3;
  while (text.contains('`' * length)) {
    length++;
  }
  return '`' * length;
}

String _duration(Evidence e) =>
    e.status == StepStatus.skipped ? '' : ReportText.duration(e.duration);

/// Markdown report, suited to pull request comments.
String renderMarkdownReport(Plan plan) {
  final commit = plan.project.gitCommit;
  final commitText =
      commit == null ? '' : ' · commit `${commit.substring(0, 7)}`';
  final b = StringBuffer()
    ..writeln(
      '## upgrade-pilot · ${plan.project.name} → Flutter '
      '${ReportText.fromTo(plan)}',
    )
    ..writeln()
    ..writeln(
      '> **${ReportText.verdictSymbol(plan.verdict)} '
      '${ReportText.verdict(plan.verdict)}** · ${plan.changes.length} '
      'changes · ${plan.dependencyUpdates.length} dependencies · '
      '${plan.blocked.length} blocked',
    )
    ..writeln('>')
    ..writeln(
      '> Android build: ${ReportText.platformStatus(plan, 'build apk')} · '
      'iOS build: ${ReportText.platformStatus(plan, 'build ios')} · '
      'Tests: ${ReportText.platformStatus(plan, 'test')}',
    )
    ..writeln()
    ..writeln('| | |')
    ..writeln('|---|---|')
    ..writeln(
      '| Project | `${_cell(plan.project.name)}` '
      '(`${_cell(plan.project.displayPath)}`) |',
    )
    ..writeln('| Flutter | ${_cell(ReportText.fromTo(plan))} |')
    ..writeln('| Platforms | ${plan.platforms.join(', ')} |')
    ..writeln(
      '| Created | ${plan.createdAt.toUtc().toIso8601String()}$commitText |',
    )
    ..writeln(
      '| Tool | upgrade-pilot ${plan.toolVersion} · KB ${plan.kbVersion} · '
      'SDK ${plan.sdkSource} · ${ReportText.duration(plan.totalDuration)} |',
    )
    ..writeln();

  if (plan.changes.isNotEmpty) {
    b
      ..writeln('### Changes')
      ..writeln();
    if (plan.verdict == Verdict.blocked) {
      b
        ..writeln(
          '_Changes of the last attempt. They did not pass verification._',
        )
        ..writeln();
    }
    for (final change in plan.changes) {
      final fence = _fence(change.diff);
      b
        ..writeln(
          '<details><summary><code>${change.path}</code> — ${_cell(change.summary)}</summary>',
        )
        ..writeln()
        ..writeln('${fence}diff')
        ..write(change.diff)
        ..writeln(fence)
        ..writeln()
        ..writeln('</details>')
        ..writeln();
    }
  }

  if (plan.dependencyUpdates.isNotEmpty) {
    b
      ..writeln('### Dependencies')
      ..writeln()
      ..writeln('| Package | Constraint | Resolved |')
      ..writeln('|---|---|---|');
    for (final d in plan.dependencyUpdates) {
      final from = _cell(d.fromConstraint ?? 'any');
      final constraint = '$from → ${_cell(d.toConstraint ?? 'any')}';
      final resolved =
          '${_cell(d.fromVersion ?? '-')} → ${_cell(d.toVersion ?? '-')}';
      b.writeln('| `${d.name}` | $constraint | $resolved |');
    }
    b.writeln();
  }

  if (plan.blocked.isNotEmpty) {
    b
      ..writeln('### Blocked')
      ..writeln();
    for (final item in plan.blocked) {
      b.writeln('- **${item.subject}**: ${item.reason}');
      if (item.suggestion != null) {
        b.writeln('  - Suggestion (not verified): ${item.suggestion}');
      }
      if (item.findingId != null) {
        b.writeln('  - Diagnosis: `${item.findingId}`');
      }
    }
    b.writeln();
  }

  if (plan.findings.isNotEmpty) {
    b
      ..writeln('### Diagnosis')
      ..writeln();
    for (final f in plan.findings) {
      b
        ..writeln(
          '#### `${f.id}` ${f.title} (${f.step}, confidence '
          '${f.confidence.name})',
        )
        ..writeln()
        ..writeln('- Cause: ${f.cause}')
        ..writeln('- Fix: ${f.fix}');
      if (f.docsUrl != null) b.writeln('- Docs: ${f.docsUrl}');
      if (f.excerpt.isNotEmpty) {
        final fence = _fence(f.excerpt);
        b
          ..writeln()
          ..writeln('${fence}text')
          ..writeln(f.excerpt)
          ..writeln(fence);
      }
      b.writeln();
    }
  }

  b
    ..writeln('### Evidence')
    ..writeln()
    ..writeln('| Attempt | Step | Command | Result | Duration |')
    ..writeln('|---|---|---|---|---|');
  for (final a in plan.attempts) {
    final result = a.succeeded ? '✔ passed' : '✖ ${a.findingId ?? 'failed'}';
    b.writeln(
      '| ${a.number} | _attempt_ | ${_cell(a.description)} | $result | |',
    );
    for (final e in plan.evidence.where((e) => e.attempt == a.number)) {
      b.writeln(
        '| ${e.attempt} | ${e.step} | `${_cell(e.command)}` | '
        '${ReportText.symbol(e.status)} '
        '${_cell(e.detail ?? ReportText.statusWord(e.status))} | '
        '${_duration(e)} |',
      );
    }
  }
  b
    ..writeln()
    ..writeln('### Not verified')
    ..writeln();
  for (final n in plan.notVerified) {
    b.writeln('- **${n.what}**: ${n.reason}');
  }
  if (plan.manualSteps.isNotEmpty) {
    b
      ..writeln()
      ..writeln('### Manual steps')
      ..writeln();
    for (final step in plan.manualSteps) {
      b.writeln(
        '- ${step.title}${step.command == null ? '' : ': `${step.command}`'}',
      );
    }
  }
  b
    ..writeln()
    ..writeln('### Limits')
    ..writeln()
    ..writeln(ReportText.limits);
  return b.toString();
}
