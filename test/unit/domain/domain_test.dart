import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upgrade_pilot/src/domain/candidate.dart';
import 'package:upgrade_pilot/src/domain/change.dart';
import 'package:upgrade_pilot/src/domain/hashing.dart';
import 'package:upgrade_pilot/src/domain/json_reader.dart';
import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';

import '../../support/builders.dart';

void main() {
  group('parseLooseVersion', () {
    test('accepts tool versions', () {
      expect(parseLooseVersion('8.3'), Version(8, 3, 0));
      expect(parseLooseVersion('8.10.2'), Version(8, 10, 2));
      expect(parseLooseVersion('v3.24.5'), Version(3, 24, 5));
      expect(parseLooseVersion(' 9 '), Version(9, 0, 0));
      expect(parseLooseVersion('2.1.0-Beta1'), Version(2, 1, 0, pre: 'Beta1'));
      expect(parseLooseVersion('9.1.0-rc-1').toString(), '9.1.0-rc-1');
      expect(parseLooseVersion('1.2.3.4'), Version(1, 2, 3));
    });

    test('rejects non versions', () {
      expect(parseLooseVersion(null), isNull);
      expect(parseLooseVersion('latest'), isNull);
      expect(parseLooseVersion(''), isNull);
    });
  });

  test('gradleDistributionVersion follows Gradle naming', () {
    expect(gradleDistributionVersion(Version(8, 14, 0)), '8.14');
    expect(gradleDistributionVersion(Version(8, 10, 2)), '8.10.2');
    expect(gradleDistributionVersion(Version(9, 1, 0)), '9.1.0');
    expect(
      gradleDistributionVersion(Version(8, 0, 0, pre: 'rc.1')),
      '8.0-rc.1',
    );
    expect(
      gradleDistributionVersion(Version(9, 0, 0, pre: 'rc.1')),
      '9.0.0-rc.1',
    );
  });

  test('version helpers', () {
    expect(shortVersion(Version(3, 44, 8)), '3.44.8');
    expect(shortVersion(Version(3, 44, 8, pre: 'beta')), '3.44.8-beta');
    expect(
      maxVersion([null, Version(1, 0, 0), Version(2, 0, 0)]),
      Version(2, 0, 0),
    );
    expect(maxVersion([null]), isNull);
    expect(minorKey(Version(3, 44, 9)), '3.44');
  });

  group('hunks', () {
    test('round trip through applyHunks', () {
      const before = 'a\nb\nc\nd\n';
      const after = 'a\nB\nc\nd\ne\n';
      final hunks = [
        const Hunk(start: 1, deleteCount: 1, insert: ['B']),
        const Hunk(start: 4, deleteCount: 0, insert: ['e']),
      ];
      expect(applyHunks(before, hunks), after);
    });

    test('creates a file from nothing', () {
      expect(
        applyHunks(null, [
          const Hunk(start: 0, deleteCount: 0, insert: ['x', '']),
        ]),
        'x\n',
      );
    });

    test('rejects hunks outside the file', () {
      expect(
        () =>
            applyHunks('a', [const Hunk(start: 4, deleteCount: 1, insert: [])]),
        throwsFormatException,
      );
    });

    test('serializes', () {
      const hunk = Hunk(start: 2, deleteCount: 1, insert: ['x']);
      final copy = Hunk.fromJson(JsonReader(hunk.toJson()));
      expect(copy.start, 2);
      expect(copy.deleteCount, 1);
      expect(copy.insert, ['x']);
    });
  });

  test('sha256Hex', () {
    expect(
      sha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  group('JsonReader', () {
    test('reads typed values', () {
      const json = JsonReader({
        's': 'x',
        'i': 1,
        'b': true,
        'o': {'k': 'v'},
        'l': ['a'],
        'objs': [
          {'a': 1},
        ],
      });
      expect(json.string('s'), 'x');
      expect(json.optionalString('missing'), isNull);
      expect(json.integer('i'), 1);
      expect(json.optionalInt('s'), isNull);
      expect(json.boolean('b'), isTrue);
      expect(json.boolean('missing', fallback: true), isTrue);
      expect(json.object('o').string('k'), 'v');
      expect(json.optionalObject('missing').json, isEmpty);
      expect(json.strings('l'), ['a']);
      expect(json.objects('objs').single.integer('a'), 1);
    });

    test('reports wrong types as FormatException', () {
      const json = JsonReader({
        'i': 'x',
        'l': [1],
        'objs': ['x'],
      });
      expect(() => json.integer('i'), throwsFormatException);
      expect(() => json.strings('l'), throwsFormatException);
      expect(() => json.objects('objs'), throwsFormatException);
      expect(
        () => enumByName(DependencyKind.values, 'nope'),
        throwsFormatException,
      );
    });
  });

  group('Candidate', () {
    final snapshot = legacySnapshot();

    test('describes changes against the project', () {
      final candidate = Candidate(
        agp: Version(9, 0, 1),
        gradle: Version(9, 1, 0),
        kotlin: Version(2, 3, 20),
        gradleProperties: const {'android.builtInKotlin': 'false'},
        minSdk: 24,
        compileSdk: 36,
        jvmTarget: 17,
        iosPlatform: Version(13, 0, 0),
        widenSdkFor: Version(3, 12, 2),
        constraints: const {'http': '^1.6.0'},
      );
      expect(candidate.describe(snapshot), [
        'AGP 8.1.0 → 9.0.1',
        'Gradle 8.3 → 9.1.0',
        'Kotlin 1.8.22 → 2.3.20',
        'android.builtInKotlin=false',
        'minSdk → 24',
        'compileSdk → 36',
        'JVM target → 17',
        'iOS ? → 13.0.0',
        'environment.sdk allows 3.12.2',
        'http ^0.12.2 → ^1.6.0',
      ]);
    });

    test('key identifies equal candidates', () {
      final a = Candidate(
        agp: Version(8, 11, 1),
        constraints: const {'b': '1', 'a': '2'},
      );
      final b = Candidate(
        agp: Version(8, 11, 1),
        constraints: const {'a': '2', 'b': '1'},
      );
      expect(a.key, b.key);
      expect(a.withConstraints(const {'c': '3'}).key, isNot(a.key));
      expect(a.withConstraints(const {}), same(a));
      expect(a.copyWith(depth: 2).depth, 2);
    });
  });

  test('SdkLevel and IosConfig', () {
    expect('${const SdkLevel.value(21)}', '21');
    expect('${const SdkLevel.flutterManaged()}', 'flutter-managed');
    expect(
      IosConfig(
        hasPodfile: true,
        podfilePlatform: Version(12, 0, 0),
        xcodeDeploymentTarget: Version(13, 0, 0),
      ).deploymentTarget,
      Version(13, 0, 0),
    );
    expect(
      IosConfig(hasPodfile: true, podfilePlatform: Version(14, 0, 0))
          .deploymentTarget,
      Version(14, 0, 0),
    );
    expect(const IosConfig(hasPodfile: false).deploymentTarget, isNull);
  });
}
