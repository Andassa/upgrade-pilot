import 'dart:convert';

import 'package:upgrade_pilot/src/domain/plan.dart';

/// Version of the JSON report layout (`report --format json`, `--json`).
const reportSchemaVersion = 1;

/// The plan as stable JSON for machines. Edit hunks are left out: the
/// report carries the redacted diff only.
Map<String, Object?> planReportJson(Plan plan) {
  final json = plan.toJson();
  return {
    'reportSchemaVersion': reportSchemaVersion,
    ...json,
    'changes': [
      for (final change in plan.changes) {...change.toJson()}..remove('hunks'),
    ],
  };
}

String renderJsonReport(Plan plan) =>
    '${const JsonEncoder.withIndent('  ').convert(planReportJson(plan))}\n';
