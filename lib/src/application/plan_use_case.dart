import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:upgrade_pilot/src/analysis/project_inspector.dart';
import 'package:upgrade_pilot/src/analysis/pubspec_parser.dart';
import 'package:upgrade_pilot/src/application/change_summary.dart';
import 'package:upgrade_pilot/src/application/git.dart';
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/application/toolchain_probe.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/plan.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/domain/release.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/patch/materializer.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';
import 'package:upgrade_pilot/src/resolver/pub_dev.dart';
import 'package:upgrade_pilot/src/resolver/resolver.dart';
import 'package:upgrade_pilot/src/resolver/strategy.dart';
import 'package:upgrade_pilot/src/sandbox/sandbox.dart';
import 'package:upgrade_pilot/src/sdk/jdk_locator.dart';
import 'package:upgrade_pilot/src/sdk/release_catalog.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';
import 'package:upgrade_pilot/src/verify/child_environment.dart';
import 'package:upgrade_pilot/src/verify/verifier.dart';
import 'package:upgrade_pilot/src/version.dart';

@immutable
final class PlanRequest {
  const PlanRequest({
    required this.projectPath,
    this.target = 'stable',
    this.platforms,
    this.runTests = false,
    this.jobs = 1,
    this.keepSandbox = false,
    this.timeout = const Duration(minutes: 20),
    this.offline = false,
    this.maxAttempts = 6,
  });

  final String projectPath;

  /// `stable`, `beta`, `latest`, `3.44` or `3.44.9`.
  final String target;

  /// `android`, `ios`. `null` means every platform the project has.
  final Set<String>? platforms;
  final bool runTests;
  final int jobs;
  final bool keepSandbox;
  final Duration timeout;
  final bool offline;
  final int maxAttempts;
}

@immutable
final class PlanResult {
  const PlanResult(
    this.plan, {
    this.sandboxPath,
    this.releaseListFromCache = false,
  });

  final Plan plan;

  /// Set when the sandbox was kept (`--keep-sandbox`).
  final String? sandboxPath;
  final bool releaseListFromCache;
}

/// Stage identifiers reported to the [ProgressObserver].
abstract final class Stages {
  static const inspect = 'inspect';
  static const resolve = 'resolve';
  static const prepare = 'prepare';
  static const sandbox = 'sandbox';
  static const verify = 'verify';
}

/// `plan`: simulate the upgrade in a sandbox and build a verified plan.
final class PlanUseCase {
  PlanUseCase({
    required this.fs,
    required this.runner,
    required this.host,
    required this.clock,
    required this.kb,
    required this.diagnoser,
    required this.redactor,
    required this.catalog,
    required this.sdkManager,
    required this.jdkLocator,
    required this.sandboxes,
    required this.pubDev,
    required this.store,
    required this.git,
    required this.probe,
    this.observer = const SilentObserver(),
  });

  final FileSystem fs;
  final ProcessRunner runner;
  final Host host;
  final Clock clock;
  final KnowledgeBase kb;
  final Diagnoser diagnoser;
  final Redactor redactor;
  final ReleaseCatalog catalog;
  final SdkManager sdkManager;
  final JdkLocator jdkLocator;
  final SandboxFactory sandboxes;
  final PubDevClient pubDev;
  final PlanStore store;
  final GitClient git;
  final ToolchainProbe probe;
  final ProgressObserver observer;

  Future<T> _stage<T>(
    String id,
    Future<T> Function() action, {
    Map<String, Object?> args = const {},
    ({String? label, String? detail, Map<String, Object?> args}) Function(T)?
        finish,
  }) async {
    observer.stageStarted(id, args: args);
    final watch = Stopwatch()..start();
    try {
      final result = await action();
      final done = finish?.call(result);
      observer.stageFinished(
        id,
        StepStatus.ok,
        labelKey: done?.label,
        detailKey: done?.detail,
        args: {...args, ...?done?.args},
        duration: watch.elapsed,
      );
      return result;
    } on Object {
      observer.stageFinished(
        id,
        StepStatus.failed,
        args: args,
        duration: watch.elapsed,
      );
      rethrow;
    }
  }

  Future<PlanResult> execute(
    PlanRequest request, {
    CancellationToken? cancellation,
  }) async {
    final started = clock();
    final root = await fs.canonicalize(request.projectPath);

    final snapshot = await _stage(
      Stages.inspect,
      () => ProjectInspector(fs).inspect(root),
      finish: (s) =>
          (label: null, detail: 'detail.project', args: {'name': s.name}),
    );
    final global = await sdkManager.globalSdk();
    final currentFlutter = _currentFlutter(snapshot, global);

    late final FlutterRelease release;
    final index = await _stage(
      Stages.resolve,
      () async {
        final loaded = await catalog.load(offline: request.offline);
        release = loaded.resolve(request.target);
        return loaded;
      },
      args: {'target': request.target},
      finish: (i) => (
        label: 'stage.resolved',
        detail: i.fallback ? 'detail.releases.cache' : null,
        args: {
          'version': shortVersion(release.version),
          'channel': release.channel,
        },
      ),
    );
    final targetLabel = shortVersion(release.version);
    final platforms = request.platforms ??
        {if (snapshot.hasAndroid) 'android', if (snapshot.hasIos) 'ios'};
    observer.planContext(
      project: snapshot.name,
      from: currentFlutter,
      target: targetLabel,
      platforms: platforms.toList()..sort(),
    );

    final sdk = await _stage(
      Stages.prepare,
      args: {'version': targetLabel},
      () => sdkManager.obtain(
        release,
        index,
        offline: request.offline,
        cancellation: cancellation,
        onProgress: (received, total) => observer.stageProgress(
          Stages.prepare,
          total == null
              ? '${received ~/ (1024 * 1024)} MB'
              : '${(received * 100 / total).floor()}%',
        ),
      ),
      finish: (s) => (
        label: null,
        detail: 'detail.sdk.${s.source.name}',
        args: const <String, Object?>{},
      ),
    );
    final probing = (
      jdkLocator.locate(),
      probe.androidSdk(),
      probe.xcode(),
    ).wait;

    final copyRoot = await _copyRoot(snapshot, root);
    final sandbox = await _stage(
      Stages.sandbox,
      () => sandboxes.create(projectDirectory: root, copyRoot: copyRoot),
      finish: (s) => (
        label: null,
        detail: s.report.secretsExcluded == 0
            ? 'detail.files'
            : 'detail.filesSecrets',
        args: {'files': s.report.files, 'secrets': s.report.secretsExcluded},
      ),
    );

    var keep = false;
    try {
      final (jdk, androidSdk, xcode) = await probing;
      final notVerified = <NotVerified>[];
      final verifyPlan = _verifyPlan(
        snapshot,
        platforms,
        request,
        androidSdk: androidSdk,
        xcode: xcode,
        notVerified: notVerified,
      );
      final strategy = Strategy(
        StrategyContext(
          snapshot: snapshot,
          kb: kb,
          flutter: release.version,
          dart: release.dartVersion ?? Version(3, 0, 0),
          jdkMajor: jdk?.major,
        ),
        pubDev,
      );
      final deadline = started.add(request.timeout);
      final environment = childEnvironment(
        host.environment,
        sdk.root,
        windows: host.os == 'windows',
      );
      const materializer = Materializer();
      final skippedEdits = <String>{};

      observer.stageStarted(Stages.verify);
      final verifyWatch = Stopwatch()..start();
      final resolution = await Resolver(
        strategy: strategy,
        limits: ResolverLimits(
          deadline: deadline,
          maxAttempts: request.maxAttempts,
        ),
        clock: clock,
        observer: observer,
      ).run(
        (candidate, attempt) async {
          await sandbox.reset();
          skippedEdits.addAll(
            await materializer.apply(
              candidate,
              snapshot,
              read: sandbox.read,
              write: sandbox.write,
            ),
          );
          return Verifier(
            runner: runner,
            diagnoser: diagnoser,
            redactor: redactor,
            clock: clock,
          ).verify(
            projectDirectory: sandbox.projectDirectory,
            flutter: sdk.flutter,
            environment: environment,
            plan: verifyPlan,
            attempt: attempt,
            deadline: deadline,
            observer: observer,
            cancellation: cancellation,
            jobs: request.jobs,
          );
        },
        cancellation: cancellation,
      );
      final succeeded = resolution.winner != null;
      for (final step in Steps.all) {
        final reason = verifyPlan.skipped[step];
        if (reason == null || resolution.attempts.isEmpty) continue;
        observer.stepFinished(
          Evidence(
            step: step,
            command: 'flutter ${Steps.arguments(step).join(' ')}',
            status: StepStatus.skipped,
            duration: Duration.zero,
            attempt: resolution.attempts.length,
            detail: reason,
          ),
        );
      }
      observer.stageFinished(
        Stages.verify,
        succeeded ? StepStatus.ok : StepStatus.failed,
        duration: verifyWatch.elapsed,
      );
      if (resolution.stopReason == StopReason.cancelled) {
        throw const CancelledException();
      }

      final deltas = await sandbox.changes();
      final changes = [
        for (final d in deltas)
          describeChange(d.path, d.before, d.after, redactor: redactor),
        ...await _pinChanges(snapshot, root, release),
      ];
      final newPubspec = deltas.where((d) => d.path == ProjectFiles.pubspec);
      final newLock = deltas.where((d) => d.path == ProjectFiles.lock);
      final moves = dependencyMoves(
        snapshot,
        newPubspec: newPubspec.isEmpty ? null : newPubspec.first.after,
        newLock: newLock.isEmpty ? null : newLock.first.after,
      );

      for (final edit in skippedEdits) {
        notVerified.add(NotVerified(what: 'Edit skipped', reason: edit));
      }
      for (final link in sandbox.report.linksSkipped) {
        notVerified.add(
          NotVerified(
            what: 'Symbolic link $link',
            reason: 'links are not copied',
          ),
        );
      }
      if (!succeeded) {
        notVerified.add(
          NotVerified(
            what: 'Upgrade',
            reason: switch (resolution.stopReason) {
              StopReason.attemptsExhausted =>
                'no passing combination within ${request.maxAttempts} attempts',
              StopReason.timeExhausted =>
                'time budget (--timeout) exhausted before a passing build',
              StopReason.environment =>
                'the machine must be fixed first (see diagnosis)',
              StopReason.blockedDependency =>
                'dependencies cannot be resolved for the target SDK',
              _ => 'no automatic fix left to try',
            },
          ),
        );
      }
      notVerified.add(
        const NotVerified(
          what: 'Runtime behaviour',
          reason: 'a successful build does not prove that the app behaves the '
              'same; run your app and its tests',
        ),
      );

      final blocked = [...resolution.blocked];
      if (!succeeded && blocked.isEmpty && resolution.findings.isNotEmpty) {
        final f = resolution.findings.last;
        blocked.add(
          BlockedItem(
            subject: f.identified ? f.title : 'Build failure (${f.step})',
            reason: f.cause,
            findingId: f.id,
          ),
        );
      }
      final hasWarnings = resolution.lastOutcome?.hasWarnings ?? false;
      final verdict = !succeeded
          ? Verdict.blocked
          : hasWarnings
              ? Verdict.verifiedWithWarnings
              : Verdict.verified;

      final plan = Plan(
        toolVersion: packageVersion,
        kbVersion: kb.kbVersion,
        createdAt: clock(),
        project: PlanProject(
          name: snapshot.name,
          displayPath: redactor.redact(root),
          fingerprint: await projectFingerprint(fs, root),
          gitCommit: await git.head(root),
          flutterVersion: currentFlutter,
        ),
        target: release,
        sdkSource: sdk.source.name,
        platforms: platforms.toList()..sort(),
        changes: changes,
        manualSteps: _manualSteps(snapshot, release, changes),
        dependencyUpdates: [
          for (final m in moves)
            DependencyUpdate(
              name: m.name,
              fromConstraint: m.fromConstraint,
              toConstraint: m.toConstraint,
              fromVersion: m.fromVersion,
              toVersion: m.toVersion,
            ),
        ],
        blocked: blocked,
        evidence: resolution.evidence,
        attempts: resolution.attempts,
        findings: resolution.findings,
        notVerified: notVerified,
        verdict: verdict,
        totalDuration: clock().difference(started),
      );
      await store.save(root, plan);
      keep = request.keepSandbox;
      return PlanResult(
        plan,
        sandboxPath: keep ? sandbox.projectDirectory : null,
        releaseListFromCache: index.fallback,
      );
    } finally {
      if (!keep) await sandbox.dispose();
    }
  }

  String? _currentFlutter(ProjectSnapshot snapshot, SdkHandle? global) {
    final pin = snapshot.flutterPin;
    if (pin != null &&
        pin.source != FlutterPinSource.metadata &&
        parseLooseVersion(pin.version) != null) {
      return pin.version;
    }
    return global == null ? null : shortVersion(global.version);
  }

  VerifyPlan _verifyPlan(
    ProjectSnapshot snapshot,
    Set<String> platforms,
    PlanRequest request, {
    required String? androidSdk,
    required String? xcode,
    required List<NotVerified> notVerified,
  }) {
    final steps = [Steps.pubGet, Steps.analyze];
    final skipped = <String, String>{};
    void skip(String step, String what, String reason) {
      skipped[step] = reason;
      notVerified.add(NotVerified(what: what, reason: reason));
    }

    if (!platforms.contains('android')) {
      skip(Steps.buildApk, 'Android build', 'platform not selected');
    } else if (!snapshot.hasAndroid) {
      skip(
        Steps.buildApk,
        'Android build',
        'the project has no android/ folder',
      );
    } else if (androidSdk == null) {
      skip(Steps.buildApk, 'Android build', 'Android SDK not found');
    } else {
      steps.add(Steps.buildApk);
    }
    if (!platforms.contains('ios')) {
      skip(Steps.buildIos, 'iOS build', 'platform not selected');
    } else if (!snapshot.hasIos) {
      skip(Steps.buildIos, 'iOS build', 'the project has no ios/ folder');
    } else if (host.os != 'macos') {
      skip(Steps.buildIos, 'iOS build', 'requires macOS');
    } else if (xcode == null) {
      skip(Steps.buildIos, 'iOS build', 'Xcode not available');
    } else {
      steps.add(Steps.buildIos);
    }
    if (request.runTests) {
      steps.add(Steps.test);
    } else {
      skip(Steps.test, 'Tests', 'not run (use --run-tests)');
    }
    return VerifyPlan(steps: steps, skipped: skipped);
  }

  /// Copy root: the project, widened to include its workspace root and
  /// path dependencies, but never the home or filesystem root.
  Future<String> _copyRoot(ProjectSnapshot snapshot, String root) async {
    final roots = <String>[root];
    for (final dep in snapshot.pubspec.dependencies) {
      if (dep.kind != DependencyKind.path || dep.path == null) continue;
      final target = p.normalize(p.join(root, dep.path));
      if (await fs.isDirectory(target)) {
        roots.add(await fs.canonicalize(target));
      }
    }
    if (snapshot.pubspec.resolutionWorkspace) {
      var dir = p.dirname(root);
      while (dir != p.dirname(dir)) {
        final content = await fs.readString(p.join(dir, 'pubspec.yaml'));
        if (content != null) {
          try {
            if (parsePubspec(content).hasWorkspace) {
              roots.add(dir);
              break;
            }
          } on ManifestException {
            break;
          }
        }
        dir = p.dirname(dir);
      }
    }
    var common = roots.first;
    for (final r in roots.skip(1)) {
      while (!p.equals(common, r) && !p.isWithin(common, r)) {
        common = p.dirname(common);
      }
    }
    final home = host.homeDirectory;
    if (common == p.dirname(common) || p.equals(common, home)) return root;
    return common;
  }

  Future<List<Change>> _pinChanges(
    ProjectSnapshot snapshot,
    String root,
    FlutterRelease release,
  ) async {
    final pin = snapshot.flutterPin;
    final version = shortVersion(release.version);
    if (pin == null || pin.version == version) return const [];
    final path = switch (pin.source) {
      FlutterPinSource.fvmrc => ProjectFiles.fvmrc,
      FlutterPinSource.fvmConfig => ProjectFiles.fvmConfig,
      FlutterPinSource.metadata => null,
    };
    if (path == null) return const [];
    final before = await fs.readString(p.joinAll([root, ...path.split('/')]));
    if (before == null) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(before);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final key =
        decoded.containsKey('flutter') ? 'flutter' : 'flutterSdkVersion';
    final after = '${const JsonEncoder.withIndent('  ').convert({
          ...decoded,
          key: version,
        })}\n';
    return [describeChange(path, before, after, redactor: redactor)];
  }

  List<ManualStep> _manualSteps(
    ProjectSnapshot snapshot,
    FlutterRelease release,
    List<Change> changes,
  ) {
    final version = shortVersion(release.version);
    final pinned = changes.any((c) => c.kind == ChangeKind.flutterPin);
    return [
      if (!pinned)
        ManualStep(
          title: 'Switch your Flutter SDK to $version',
          command: release.channel == 'stable'
              ? 'flutter upgrade   (or: fvm use $version)'
              : 'fvm use $version',
        ),
      if (pinned)
        ManualStep(
          title: 'Install the pinned SDK',
          command: 'fvm install $version',
        ),
      if (snapshot.hasIos && changes.any((c) => c.path.startsWith('ios/')))
        const ManualStep(
          title: 'Refresh iOS pods',
          command: 'cd ios && pod install',
        ),
    ];
  }
}
