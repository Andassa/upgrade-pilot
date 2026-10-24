import 'package:upgrade_pilot/src/application/apply_use_case.dart';
import 'package:upgrade_pilot/src/application/doctor_use_case.dart';
import 'package:upgrade_pilot/src/application/git.dart';
import 'package:upgrade_pilot/src/application/maintenance_use_cases.dart';
import 'package:upgrade_pilot/src/application/plan_store.dart';
import 'package:upgrade_pilot/src/application/plan_use_case.dart';
import 'package:upgrade_pilot/src/application/toolchain_probe.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/diagnose/embedded_rules.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/redaction.dart';
import 'package:upgrade_pilot/src/kb/kb_loader.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/ports/progress.dart';
import 'package:upgrade_pilot/src/resolver/pub_dev.dart';
import 'package:upgrade_pilot/src/sandbox/sandbox.dart';
import 'package:upgrade_pilot/src/sdk/jdk_locator.dart';
import 'package:upgrade_pilot/src/sdk/release_catalog.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';

/// Composition root: wires ports into use cases. Tests pass fakes.
final class Services {
  Services({
    required this.fs,
    required this.runner,
    required this.http,
    required this.host,
    required this.clock,
    required this.console,
  });

  final FileSystem fs;
  final ProcessRunner runner;
  final HttpPort http;
  final Host host;
  final Clock clock;
  final Console console;

  late final redactor = Redactor(homeDirectory: host.homeDirectory);
  late final rules = RuleSet.parse(embeddedRules);
  late final diagnoser = Diagnoser(rules, redactor: redactor);
  late final kbLoader = KbLoader(fs, host.cacheDirectory);
  late final sandboxes = SandboxFactory(fs, host);
  late final store = PlanStore(fs, host);
  late final git = GitClient(runner, host.environment);
  late final probe = ToolchainProbe(fs: fs, runner: runner, host: host);
  late final sdkManager = SdkManager(
    fs: fs,
    runner: runner,
    http: http,
    host: host,
  );
  late final jdkLocator = JdkLocator(fs: fs, runner: runner, host: host);
  late final catalog = ReleaseCatalog(
    http: http,
    fs: fs,
    host: host,
    clock: clock,
  );

  Future<KnowledgeBase> knowledgeBase() => kbLoader.load();

  PubDevClient pubDev({required bool offline}) => PubDevClient(
        http: http,
        fs: fs,
        host: host,
        clock: clock,
        offline: offline,
      );

  Future<PlanUseCase> planUseCase({
    required bool offline,
    required ProgressObserver observer,
  }) async =>
      PlanUseCase(
        fs: fs,
        runner: runner,
        host: host,
        clock: clock,
        kb: await knowledgeBase(),
        diagnoser: diagnoser,
        redactor: redactor,
        catalog: catalog,
        sdkManager: sdkManager,
        jdkLocator: jdkLocator,
        sandboxes: sandboxes,
        pubDev: pubDev(offline: offline),
        store: store,
        git: git,
        probe: probe,
        observer: observer,
      );

  ApplyUseCase applyUseCase() => ApplyUseCase(
        fs: fs,
        host: host,
        clock: clock,
        store: store,
        git: git,
      );

  Future<DoctorUseCase> doctorUseCase() async => DoctorUseCase(
        fs: fs,
        http: http,
        host: host,
        sdkManager: sdkManager,
        jdkLocator: jdkLocator,
        probe: probe,
        kb: await knowledgeBase(),
      );

  ExplainUseCase explainUseCase() => ExplainUseCase(store, rules);

  KbUpdateUseCase kbUpdateUseCase() =>
      KbUpdateUseCase(http: http, fs: fs, loader: kbLoader);

  CleanUseCase cleanUseCase() => CleanUseCase(fs, host);
}
