import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/diagnose/diagnoser.dart';
import 'package:upgrade_pilot/src/diagnose/rules.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/finding.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/kb/kb_loader.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/resolver/pub_dev.dart';
import 'package:upgrade_pilot/src/resolver/resolver.dart';
import 'package:upgrade_pilot/src/resolver/strategy.dart';
import 'package:upgrade_pilot/src/verify/verifier.dart';

import '../../support/builders.dart';
import '../../support/fakes.dart';

Map<String, Object?> package(
  String name,
  List<(String, String?, String?)> versions, {
  bool discontinued = false,
  String? replacedBy,
}) =>
    {
      'name': name,
      'isDiscontinued': discontinued,
      if (replacedBy != null) 'replacedBy': replacedBy,
      'versions': [
        for (final (v, sdk, flutter) in versions)
          {
            'version': v,
            'pubspec': {
              'environment': {
                if (sdk != null) 'sdk': sdk,
                if (flutter != null) 'flutter': flutter,
              },
            },
          },
      ],
    };

Diagnosis diagnosis(
  String id,
  FixAction action, {
  Map<String, String> captures = const {},
  String category = 'android',
  String step = 'build apk',
}) =>
    Diagnosis(
      Finding(
        id: id,
        title: id,
        cause: 'c',
        fix: 'f',
        confidence: Confidence.high,
        step: step,
        captures: captures,
      ),
      action,
      category: category,
    );

void main() {
  final kb = KbLoader.embedded();
  final clock = steppingClock(DateTime.utc(2026, 10, 24));

  group('pub.dev compatibility', () {
    test('Dart 3 reads <3.0.0 upper bounds of null-safe packages as <4.0.0',
        () {
      final dart = Version(3, 12, 2);
      expect(
        sdkAllows(VersionConstraint.parse('>=2.12.0 <3.0.0'), dart),
        isTrue,
      );
      expect(
        sdkAllows(VersionConstraint.parse('>=2.7.0 <3.0.0'), dart),
        isFalse,
      );
      expect(sdkAllows(VersionConstraint.parse('^3.5.0'), dart), isTrue);
      expect(
        sdkAllows(
          VersionConstraint.parse('>=2.12.0 <3.0.0'),
          Version(2, 19, 0),
        ),
        isTrue,
      );
    });

    test('Flutter upper bounds are ignored', () {
      final flutter = Version(3, 44, 9);
      expect(flutterAllows(null, flutter), isTrue);
      expect(
        flutterAllows(VersionConstraint.parse('>=3.0.0 <3.10.0'), flutter),
        isTrue,
      );
      expect(
        flutterAllows(VersionConstraint.parse('>=3.50.0'), flutter),
        isFalse,
      );
      expect(
        flutterAllows(VersionConstraint.parse('>3.44.9'), flutter),
        isFalse,
      );
      expect(flutterAllows(VersionConstraint.parse('<4.0.0'), flutter), isTrue);
      expect(flutterAllows(VersionConstraint.parse('3.44.9'), flutter), isTrue);
    });
  });

  group('PubDevClient', () {
    late FakeHttp http;
    late MemoryFileSystem fs;
    PubDevClient client({bool offline = false}) => PubDevClient(
          http: http,
          fs: fs,
          host: FakeHost(),
          clock: clock,
          offline: offline,
        );

    setUp(() {
      http = FakeHttp();
      fs = MemoryFileSystem();
    });

    test('picks the newest stable, non-retracted compatible version', () async {
      http.json('https://pub.dev/api/packages/http', {
        ...package('http', [
          ('0.12.2', '>=2.0.0 <3.0.0', null),
          ('1.5.0', '^3.4.0', null),
          ('1.6.0', '^3.4.0', null),
          ('1.7.0-dev', '^3.4.0', null),
          ('2.0.0', '^3.20.0', null),
        ]),
      });
      final latest = await client().latestCompatible(
        'http',
        dart: Version(3, 12, 2),
        flutter: Version(3, 44, 9),
      );
      expect(latest, Version(1, 6, 0));
      expect(http.requested, hasLength(1));
      await client().latestCompatible(
        'http',
        dart: Version(3, 12, 2),
        flutter: Version(3, 44, 9),
      );
      expect(http.requested, hasLength(1), reason: 'served from cache');
    });

    test('returns null without compatible version, or offline without cache',
        () async {
      http.json(
        'https://pub.dev/api/packages/old',
        package('old', [('1.0.0', '>=2.0.0 <3.0.0', null)]),
      );
      expect(
        await client().latestCompatible(
          'old',
          dart: Version(3, 0, 0),
          flutter: Version(3, 10, 0),
        ),
        isNull,
      );
      expect(await client(offline: true).package('other'), isNull);
      expect(await client().package('Bad-Name'), isNull);
      expect(await client().package('missing'), isNull, reason: '404');
      http.offline = true;
      expect(await client().package('network_down'), isNull);
      expect(await client().package('old'), isNotNull, reason: 'cached copy');
      http
        ..text('https://pub.dev/api/packages/garbage', 'nope')
        ..offline = false;
      expect(await client().package('garbage'), isNull);
    });

    test('parses discontinued packages and odd versions', () {
      final pkg = PubPackage.parse(
        jsonEncode({
          'name': 'p',
          'isDiscontinued': true,
          'replacedBy': 'q',
          'versions': [
            {'version': 'x'},
            {
              'version': '1.0.0',
              'retracted': true,
              'pubspec': {
                'environment': {'sdk': 'bad'},
              },
            },
          ],
        }),
      );
      expect(pkg.discontinued, isTrue);
      expect(pkg.replacedBy, 'q');
      expect(pkg.versions.single.retracted, isTrue);
      expect(pkg.versions.single.sdk, isNull);
      expect(() => PubPackage.parse('[]'), throwsFormatException);
    });
  });

  group('Strategy', () {
    late FakeHttp http;
    Strategy strategy({
      int? jdk = 25,
      ProjectSnapshot? snapshot,
      String flutter = '3.44.9',
    }) =>
        Strategy(
          StrategyContext(
            snapshot: snapshot ?? legacySnapshot(),
            kb: kb,
            flutter: Version.parse(flutter),
            dart: Version(3, 12, 2),
            jdkMajor: jdk,
          ),
          PubDevClient(
            http: http,
            fs: MemoryFileSystem(),
            host: FakeHost(),
            clock: clock,
          ),
        );

    setUp(() => http = FakeHttp());

    test('initial candidates: minimal, then the target template', () {
      final candidates = strategy().initialCandidates();
      expect(candidates, hasLength(2));
      final minimal = candidates.first;
      expect(minimal.origin, 'minimal');
      expect(minimal.agp, Version(8, 11, 1));
      expect(minimal.kotlin, Version(2, 2, 20));
      expect(
        minimal.gradle,
        Version(9, 1, 0),
        reason: 'JDK 25 needs Gradle 9.1',
      );
      expect(minimal.gradleProperties, isEmpty);
      final template = candidates.last;
      expect(template.agp, Version(9, 0, 1));
      expect(template.gradleProperties, {
        'android.newDsl': 'false',
        'android.builtInKotlin': 'false',
      });
    });

    test('without JDK, Gradle follows AGP and Flutter only', () {
      final minimal = strategy(jdk: null).initialCandidates().first;
      expect(minimal.gradle, Version(8, 14, 0));
    });

    test('unknown Flutter minor keeps the toolchain and relies on the build',
        () {
      final candidates = strategy(flutter: '9.0.0').initialCandidates();
      expect(candidates.single.agp, isNull);
      expect(candidates.single.gradle, Version(9, 1, 0));
    });

    test('a project without android gets one empty candidate', () {
      final s = legacySnapshot();
      final noAndroid =
          ProjectSnapshot(rootPath: '/p', pubspec: s.pubspec, lock: const {});
      expect(
        strategy(snapshot: noAndroid).initialCandidates().single.key,
        const Candidate().key,
      );
    });

    test('fixes for toolchain diagnoses', () async {
      final s = strategy();
      const base = Candidate();
      Future<Candidate?> next(Diagnosis d, [Candidate from = base]) async {
        final result = await s.fix(from, d);
        return result is NextCandidate ? result.candidate : null;
      }

      expect(
        (await next(
          diagnosis(
            'UP-AND-0001',
            FixAction.gradleForJdk,
            captures: {'java': '25'},
          ),
        ))!
            .gradle,
        Version(9, 1, 0),
      );
      expect(
        (await next(
          diagnosis(
            'UP-AND-0001',
            FixAction.gradleForJdk,
            captures: {'major': '68'},
          ),
        ))!
            .gradle,
        Version(8, 14, 0),
      );
      final agp = (await next(
        diagnosis(
          'UP-AND-0002',
          FixAction.bumpAgp,
          captures: {'min': '8.6.0'},
        ),
      ))!;
      expect(agp.agp, Version(8, 11, 1));
      expect(agp.gradle, Version(9, 1, 0));
      expect(agp.depth, 1);
      expect(agp.origin, 'UP-AND-0002');
      expect(
        (await next(
          diagnosis(
            'UP-AND-0006',
            FixAction.bumpGradle,
            captures: {'min': '8.13'},
          ),
        ))!
            .gradle,
        Version(8, 13, 0),
      );
      expect(
        (await next(diagnosis('UP-AND-0010', FixAction.bumpGradle)))!.gradle,
        Version(9, 1, 0),
      );
      expect(
        (await next(
          diagnosis(
            'UP-AND-0004',
            FixAction.bumpKotlin,
            captures: {'min': '2.0.0'},
          ),
        ))!
            .kotlin,
        Version(2, 2, 20),
      );
      expect(
        (await next(
          diagnosis('UP-AND-0007', FixAction.disableBuiltInKotlin),
        ))!
            .gradleProperties,
        {'android.builtInKotlin': 'false'},
      );
      expect(
        (await next(diagnosis('UP-AND-0008', FixAction.disableNewDsl)))!
            .gradleProperties,
        {'android.newDsl': 'false'},
      );
      expect(
        (await next(
          diagnosis(
            'UP-AND-0011',
            FixAction.setMinSdk,
            captures: {'min': '23'},
          ),
        ))!
            .minSdk,
        23,
      );
      expect(
        (await next(
          diagnosis(
            'UP-AND-0012',
            FixAction.setCompileSdk,
            captures: {'min': '35'},
          ),
        ))!
            .compileSdk,
        35,
      );
      expect(
        (await next(
          diagnosis('UP-AND-0015', FixAction.bumpAgpForCompileSdk),
        ))!
            .agp,
        Version(8, 9, 1),
      );
      expect(
        (await next(
          diagnosis(
            'UP-AND-0018',
            FixAction.normalizeGradleDistribution,
            captures: {'version': '8.14.0'},
          ),
        ))!
            .gradle,
        Version(8, 14, 0),
      );
      expect(
        (await next(diagnosis('UP-AND-0020', FixAction.alignJvmTarget)))!
            .jvmTarget,
        17,
      );
      expect(
        await next(
          diagnosis('UP-AND-0020', FixAction.alignJvmTarget),
          const Candidate(jvmTarget: 17),
        ),
        isNull,
      );
      expect(
        (await next(
          diagnosis('UP-IOS-0001', FixAction.setIosDeploymentTarget),
        ))!
            .iosPlatform,
        Version(13, 0, 0),
      );
      expect(
        (await next(diagnosis('UP-PUB-0006', FixAction.widenSdkConstraint)))!
            .widenSdkFor,
        Version(3, 12, 2),
      );
      expect(await next(diagnosis('UP-ENV-0001', FixAction.none)), isNull);
      expect(await next(diagnosis('UP-AND-0011', FixAction.setMinSdk)), isNull);
      expect(
        await next(
          diagnosis('UP-AND-0007', FixAction.disableBuiltInKotlin),
          const Candidate(
            gradleProperties: {'android.builtInKotlin': 'false'},
          ),
        ),
        isNull,
      );
    });

    test('dependency fixes', () async {
      http
        ..json(
          'https://pub.dev/api/packages/http',
          package('http', [('1.6.0', '^3.4.0', null)]),
        )
        ..json(
          'https://pub.dev/api/packages/progress_dialog',
          package(
            'progress_dialog',
            [('1.2.4', '>=2.7.0 <3.0.0', null)],
            discontinued: true,
            replacedBy: 'other_dialog',
          ),
        );
      final s = strategy(
        snapshot: legacySnapshot(
          lock: const {
            'http': LockedPackage(
              name: 'http',
              version: '0.12.2',
              source: 'hosted',
              dependency: 'direct main',
            ),
          },
        ),
      );
      final suggested = await s.fix(
        const Candidate(),
        diagnosis(
          'UP-PUB-0002',
          FixAction.setConstraint,
          captures: {'package': 'http', 'constraint': '^1.6.0'},
          category: 'pub',
        ),
      );
      expect(
        (suggested as NextCandidate).dependencyConstraints,
        {'http': '^1.6.0'},
      );
      final again = await s.fix(
        const Candidate(constraints: {'http': '^1.6.0'}),
        diagnosis(
          'UP-PUB-0002',
          FixAction.setConstraint,
          captures: {'package': 'http', 'constraint': '^1.6.0'},
        ),
      );
      expect(again, isA<NoFix>());

      final upgraded = await s.fix(
        const Candidate(),
        diagnosis(
          'UP-PUB-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'http'},
        ),
      );
      expect(
        (upgraded as NextCandidate).candidate.constraints,
        {'http': '^1.6.0'},
      );

      final transitive = await s.fix(
        const Candidate(),
        diagnosis(
          'UP-DART-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'meta'},
        ),
      );
      expect((transitive as Blocked).item.reason, contains('Transitive'));

      final local = await s.fix(
        const Candidate(),
        diagnosis(
          'UP-DART-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'local_pkg'},
        ),
      );
      expect((local as Blocked).item.reason, contains('path'));

      final s2 = Strategy(
        StrategyContext(
          snapshot: const ProjectSnapshot(
            rootPath: '/p',
            pubspec: PubspecInfo(
              name: 'a',
              dependencies: [
                DependencySpec(
                  name: 'progress_dialog',
                  kind: DependencyKind.hosted,
                  constraint: '^1.2.4',
                ),
                DependencySpec(
                  name: 'http',
                  kind: DependencyKind.hosted,
                  constraint: '^1.6.0',
                ),
              ],
            ),
            lock: {},
          ),
          kb: kb,
          flutter: Version(3, 44, 9),
          dart: Version(3, 12, 2),
        ),
        PubDevClient(
          http: http,
          fs: MemoryFileSystem(),
          host: FakeHost(),
          clock: clock,
        ),
      );
      final blocked = await s2.fix(
        const Candidate(),
        diagnosis(
          'UP-PUB-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'progress_dialog'},
        ),
      );
      final item = (blocked as Blocked).item;
      expect(item.subject, 'progress_dialog ^1.2.4');
      expect(item.reason, contains('(discontinued)'));
      expect(item.suggestion, contains('other_dialog'));
      final stillFailing = await s2.fix(
        const Candidate(),
        diagnosis(
          'UP-DART-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'http'},
        ),
      );
      expect(
        (stillFailing as Blocked).item.reason,
        contains('newest compatible'),
      );
      final unknown = await s2.fix(
        const Candidate(),
        diagnosis(
          'UP-PUB-0001',
          FixAction.upgradeDependency,
          captures: {'package': 'unknown_pkg'},
        ),
      );
      expect(unknown, isA<Blocked>());
      expect(
        await s2.fix(
          const Candidate(),
          diagnosis('X', FixAction.upgradeDependency),
        ),
        isA<NoFix>(),
      );
    });
  });

  group('Resolver', () {
    AttemptOutcome failing(Diagnosis d, {String step = Steps.buildApk}) =>
        AttemptOutcome(
          evidence: [
            Evidence(
              step: step,
              command: 'flutter',
              status: StepStatus.failed,
              duration: Duration.zero,
              attempt: 1,
              findingId: d.finding.id,
            ),
          ],
          diagnoses: [d],
          failedStep: step,
        );
    const passing = AttemptOutcome(evidence: [], diagnoses: []);

    Resolver resolver({int maxAttempts = 6, DateTime? deadline}) => Resolver(
          strategy: Strategy(
            StrategyContext(
              snapshot: legacySnapshot(),
              kb: kb,
              flutter: Version(3, 44, 9),
              dart: Version(3, 12, 2),
              jdkMajor: 25,
            ),
            PubDevClient(
              http: FakeHttp(),
              fs: MemoryFileSystem(),
              host: FakeHost(),
              clock: clock,
            ),
          ),
          limits: ResolverLimits(
            deadline: deadline ?? DateTime.utc(2100),
            maxAttempts: maxAttempts,
          ),
          clock: () => DateTime.utc(2026),
        );

    test('derives a fix from the diagnosis and succeeds', () async {
      final tried = <Candidate>[];
      final result = await resolver().run((candidate, attempt) async {
        tried.add(candidate);
        if (attempt == 1) {
          return failing(
            diagnosis('UP-AND-0007', FixAction.disableBuiltInKotlin),
          );
        }
        return passing;
      });
      expect(result.stopReason, StopReason.success);
      expect(result.winner!.gradleProperties['android.builtInKotlin'], 'false');
      expect(result.attempts.map((a) => a.succeeded), [false, true]);
      expect(result.findings.single.id, 'UP-AND-0007');
      expect(tried[1].depth, 1);
    });

    test('backtracks to the next initial candidate', () async {
      final result = await resolver().run((candidate, attempt) async {
        if (candidate.origin == 'minimal') {
          return failing(
            diagnosis(
              Finding.unidentifiedId,
              FixAction.none,
              category: 'unknown',
            ),
          );
        }
        return passing;
      });
      expect(result.winner!.origin, 'target template');
      expect(result.attempts, hasLength(2));
    });

    test('stops on environment problems', () async {
      final result = await resolver().run(
        (c, a) async => failing(
          diagnosis('UP-ENV-0001', FixAction.none, category: 'environment'),
        ),
      );
      expect(result.stopReason, StopReason.environment);
      expect(result.attempts, hasLength(1));
    });

    test('stops when a dependency is blocked at pub get', () async {
      final result = await resolver().run(
        (c, a) async => failing(
          diagnosis(
            'UP-PUB-0001',
            FixAction.upgradeDependency,
            captures: {'package': 'meta'},
            category: 'pub',
            step: Steps.pubGet,
          ),
          step: Steps.pubGet,
        ),
      );
      expect(result.stopReason, StopReason.blockedDependency);
      expect(result.blocked.single.subject, startsWith('meta'));
    });

    test('learned dependency constraints apply to later candidates', () async {
      final seen = <Candidate>[];
      await resolver().run((candidate, attempt) async {
        seen.add(candidate);
        if (attempt == 1) {
          return failing(
            diagnosis(
              'UP-PUB-0002',
              FixAction.setConstraint,
              captures: {'package': 'http', 'constraint': '^1.6.0'},
              category: 'pub',
              step: Steps.pubGet,
            ),
            step: Steps.pubGet,
          );
        }
        return failing(
          diagnosis(
            Finding.unidentifiedId,
            FixAction.none,
            category: 'unknown',
          ),
        );
      });
      expect(
        seen.skip(1).every((c) => c.constraints['http'] == '^1.6.0'),
        isTrue,
      );
      expect(seen.last.origin, 'target template');
    });

    test('respects attempt and time budgets, and cancellation', () async {
      var n = 0;
      final limited = await resolver(maxAttempts: 1).run((c, a) async {
        n++;
        return failing(
          diagnosis(
            'UP-AND-0011',
            FixAction.setMinSdk,
            captures: {'min': '23'},
          ),
        );
      });
      expect(limited.stopReason, StopReason.attemptsExhausted);
      expect(n, 1);

      final late = await resolver(deadline: DateTime.utc(2000))
          .run((c, a) async => passing);
      expect(late.stopReason, StopReason.timeExhausted);
      expect(late.attempts, isEmpty);

      final token = CancellationToken()..cancel();
      final cancelled =
          await resolver().run((c, a) async => passing, cancellation: token);
      expect(cancelled.stopReason, StopReason.cancelled);

      final interrupted = await resolver().run(
        (c, a) async =>
            const AttemptOutcome(evidence: [], diagnoses: [], cancelled: true),
      );
      expect(interrupted.stopReason, StopReason.cancelled);
    });

    test('runs out of candidates', () async {
      final result = await resolver().run(
        (c, a) async => failing(
          diagnosis(
            Finding.unidentifiedId,
            FixAction.none,
            category: 'unknown',
          ),
        ),
      );
      expect(result.stopReason, StopReason.noCandidateLeft);
      expect(result.attempts, hasLength(2));
      expect(result.winner, isNull);
    });
  });
}
