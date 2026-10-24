import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/report/report_text.dart';

String _e(String? text) => (text ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _status(StepStatus status) {
  final cls = switch (status) {
    StepStatus.ok => 'ok',
    StepStatus.warning => 'warn',
    StepStatus.failed => 'fail',
    StepStatus.skipped => 'skip',
  };
  return '<span class="st $cls"><span aria-hidden="true">'
      '${ReportText.symbol(status)}</span> ${ReportText.statusWord(status)}</span>';
}

String _tableHead(List<String> columns) => '<table><thead><tr>'
    '${columns.map((c) => '<th scope="col">${_e(c)}</th>').join()}'
    '</tr></thead><tbody>\n';

String _diff(String diff) {
  final b = StringBuffer('<pre class="diff" tabindex="0"><code>');
  for (final line in diff.trimRight().split('\n')) {
    final cls = line.startsWith('+++') || line.startsWith('---')
        ? 'meta'
        : line.startsWith('+')
            ? 'add'
            : line.startsWith('-')
                ? 'del'
                : line.startsWith('@@')
                    ? 'hunk'
                    : '';
    b.write('<span class="$cls">${_e(line)}</span>\n');
  }
  return (b..write('</code></pre>')).toString();
}

const _css = '''
:root{color-scheme:light dark;--bg:#fbfbfd;--fg:#1d1d24;--muted:#5b5f6e;--card:#fff;--line:#e3e4ea;--accent:#6d4fd8;--ok:#16794a;--warn:#8a6100;--fail:#b4232c;--add:#e7f6ec;--del:#fbe9ea;--code:#f4f4f8}
@media (prefers-color-scheme:dark){:root{--bg:#121218;--fg:#e9e9f0;--muted:#a3a6b8;--card:#1b1b24;--line:#2c2c3a;--accent:#b8a4ff;--ok:#5fd394;--warn:#f2c84b;--fail:#ff8a8f;--add:#173323;--del:#3b1a1d;--code:#17171f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--accent)}a:focus,summary:focus,pre:focus{outline:3px solid var(--accent);outline-offset:2px}
.skip-link{position:absolute;left:-999px}.skip-link:focus{left:1rem;top:1rem;background:var(--card);padding:.5rem}
main{max-width:980px;margin:0 auto;padding:2rem 1.25rem 4rem}
header .brand{font-weight:700;color:var(--accent);letter-spacing:.02em}
h1{font-size:1.6rem;margin:.25rem 0 1rem}h2{font-size:1.15rem;margin:2.2rem 0 .8rem;padding-bottom:.3rem;border-bottom:1px solid var(--line)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:1rem 1.25rem}
.verdict{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}.verdict strong{font-size:1.15rem}
.st{font-weight:600;white-space:nowrap}.ok{color:var(--ok)}.warn{color:var(--warn)}.fail{color:var(--fail)}.skip{color:var(--muted)}
.muted{color:var(--muted)}
table{border-collapse:collapse;width:100%;margin:.5rem 0}th,td{text-align:left;padding:.45rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600}
code,pre{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:.75rem;overflow:auto}
.diff .add{background:var(--add);display:inline-block;width:100%}.diff .del{background:var(--del);display:inline-block;width:100%}.diff .hunk{color:var(--accent)}.diff .meta{color:var(--muted)}
details{margin:.4rem 0}summary{cursor:pointer;padding:.3rem 0}
ul{padding-left:1.2rem}footer{margin-top:3rem;color:var(--muted);font-size:.85rem}
''';

/// Self-contained HTML report: inline CSS, no script, no external
/// resource, light and dark themes, keyboard accessible.
String renderHtmlReport(Plan plan) {
  final verdictClass = switch (plan.verdict) {
    Verdict.verified => 'ok',
    Verdict.verifiedWithWarnings => 'warn',
    Verdict.blocked => 'fail',
  };
  final b = StringBuffer()
    ..write(
      '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n',
    )
    ..write(
      '<meta name="viewport" content="width=device-width,initial-scale=1">\n',
    )
    ..write(
      '<meta http-equiv="Content-Security-Policy" '
      'content="default-src \'none\'; style-src \'unsafe-inline\'">\n',
    )
    ..write(
      '<title>upgrade-pilot · ${_e(plan.project.name)} → Flutter ${_e(ReportText.fromTo(plan))}</title>\n',
    )
    ..write('<style>$_css</style>\n</head>\n<body>\n')
    ..write('<a class="skip-link" href="#main">Skip to content</a>\n')
    ..write(
      '<main id="main">\n<header><div class="brand">upgrade-pilot</div>\n',
    )
    ..write(
      '<h1>${_e(plan.project.name)} → Flutter ${_e(ReportText.fromTo(plan))}</h1></header>\n',
    )
    ..write('<section class="card verdict" aria-label="Verdict">')
    ..write(
      '<strong class="$verdictClass"><span aria-hidden="true">'
      '${ReportText.verdictSymbol(plan.verdict)}</span> '
      '${ReportText.verdict(plan.verdict)}</strong>',
    )
    ..write(
      '<span>${plan.changes.length} changes · ${plan.dependencyUpdates.length} '
      'dependencies · ${plan.blocked.length} blocked</span>',
    )
    ..write('</section>\n')
    ..write('<h2>Context</h2>\n<table>\n')
    ..write(
      '<tr><th scope="row">Project</th><td><code>${_e(plan.project.displayPath)}</code></td></tr>\n',
    )
    ..write(
      '<tr><th scope="row">Flutter</th><td>${_e(ReportText.fromTo(plan))}</td></tr>\n',
    )
    ..write(
      '<tr><th scope="row">Platforms</th><td>${_e(plan.platforms.join(', '))}</td></tr>\n',
    )
    ..write(
      '<tr><th scope="row">Builds</th><td>Android: ${_e(ReportText.platformStatus(plan, 'build apk'))} · '
      'iOS: ${_e(ReportText.platformStatus(plan, 'build ios'))} · Tests: ${_e(ReportText.platformStatus(plan, 'test'))}</td></tr>\n',
    )
    ..write(
      '<tr><th scope="row">Created</th><td>${_e(plan.createdAt.toUtc().toIso8601String())}'
      '${plan.project.gitCommit == null ? '' : ' · commit <code>${_e(plan.project.gitCommit!.substring(0, 7))}</code>'}</td></tr>\n',
    )
    ..write(
      '<tr><th scope="row">Tool</th><td>upgrade-pilot ${_e(plan.toolVersion)} · KB ${_e(plan.kbVersion)} · '
      'SDK ${_e(plan.sdkSource)} · ${ReportText.duration(plan.totalDuration)}</td></tr>\n',
    )
    ..write('</table>\n');

  if (plan.changes.isNotEmpty) {
    b.write('<h2>Changes</h2>\n');
    if (plan.verdict == Verdict.blocked) {
      b.write(
        '<p class="muted">Changes of the last attempt. They did not pass verification.</p>\n',
      );
    }
    for (final c in plan.changes) {
      b
        ..write(
          '<details><summary><code>${_e(c.path)}</code> — ${_e(c.summary)}</summary>\n',
        )
        ..write(_diff(c.diff))
        ..write('</details>\n');
    }
  }
  if (plan.dependencyUpdates.isNotEmpty) {
    b
      ..write('<h2>Dependencies</h2>\n')
      ..write(_tableHead(['Package', 'Constraint', 'Resolved']));
    for (final d in plan.dependencyUpdates) {
      b.write(
        '<tr><td><code>${_e(d.name)}</code></td><td>${_e(d.fromConstraint ?? 'any')} → '
        '${_e(d.toConstraint ?? 'any')}</td><td>${_e(d.fromVersion ?? '-')} → ${_e(d.toVersion ?? '-')}</td></tr>\n',
      );
    }
    b.write('</tbody></table>\n');
  }
  if (plan.blocked.isNotEmpty) {
    b.write('<h2>Blocked</h2>\n<ul>\n');
    for (final item in plan.blocked) {
      b.write(
        '<li><strong class="fail">${_e(item.subject)}</strong>: ${_e(item.reason)}',
      );
      if (item.suggestion != null) {
        b.write(
          '<br><span class="muted">Suggestion (not verified): ${_e(item.suggestion)}</span>',
        );
      }
      b.write('</li>\n');
    }
    b.write('</ul>\n');
  }
  if (plan.findings.isNotEmpty) {
    b.write('<h2>Diagnosis</h2>\n');
    for (final f in plan.findings) {
      b
        ..write('<section class="card" aria-label="${_e(f.id)}">')
        ..write('<p><code>${_e(f.id)}</code> <strong>${_e(f.title)}</strong> ')
        ..write(
          '<span class="muted">(${_e(f.step)}, confidence ${f.confidence.name})</span></p>',
        )
        ..write(
          '<p><strong>Cause:</strong> ${_e(f.cause)}</p><p><strong>Fix:</strong> ${_e(f.fix)}</p>',
        );
      if (f.docsUrl != null) {
        b.write(
          '<p><a href="${_e(f.docsUrl)}" rel="noreferrer">${_e(f.docsUrl)}</a></p>',
        );
      }
      if (f.excerpt.isNotEmpty) {
        b.write('<pre tabindex="0"><code>${_e(f.excerpt)}</code></pre>');
      }
      b.write('</section>\n');
    }
  }
  b
    ..write('<h2>Evidence</h2>\n')
    ..write(_tableHead(['#', 'Step', 'Command', 'Result', 'Duration']));
  for (final a in plan.attempts) {
    b.write(
      '<tr><td>${a.number}</td><td colspan="4" class="muted">Attempt: ${_e(a.description)}</td></tr>\n',
    );
    for (final e in plan.evidence.where((x) => x.attempt == a.number)) {
      b.write(
        '<tr><td>${e.attempt}</td><td>${_e(e.step)}</td><td><code>${_e(e.command)}</code></td>'
        '<td>${_status(e.status)}${e.detail == null ? '' : ' <span class="muted">${_e(e.detail)}</span>'}</td>'
        '<td>${e.status == StepStatus.skipped ? '' : ReportText.duration(e.duration)}</td></tr>\n',
      );
    }
  }
  b
    ..write('</tbody></table>\n')
    ..write('<h2>Not verified</h2>\n<ul>\n');
  for (final n in plan.notVerified) {
    b.write('<li><strong>${_e(n.what)}</strong>: ${_e(n.reason)}</li>\n');
  }
  b.write('</ul>\n');
  if (plan.manualSteps.isNotEmpty) {
    b.write('<h2>Manual steps</h2>\n<ul>\n');
    for (final s in plan.manualSteps) {
      b.write(
        '<li>${_e(s.title)}${s.command == null ? '' : ': <code>${_e(s.command)}</code>'}</li>\n',
      );
    }
    b.write('</ul>\n');
  }
  b
    ..write('<h2>Limits</h2>\n<p>${_e(ReportText.limits)}</p>\n')
    ..write(
      '<footer>Generated by upgrade-pilot ${_e(plan.toolVersion)}. No telemetry; this file has no external resource.</footer>\n',
    )
    ..write('</main>\n</body>\n</html>\n');
  return b.toString();
}
