import 'package:meta/meta.dart';
import 'package:upgrade_pilot/src/application/toolchain_probe.dart';
import 'package:upgrade_pilot/src/domain/evidence.dart';
import 'package:upgrade_pilot/src/domain/versions.dart';
import 'package:upgrade_pilot/src/kb/knowledge_base.dart';
import 'package:upgrade_pilot/src/ports/ports.dart';
import 'package:upgrade_pilot/src/sdk/jdk_locator.dart';
import 'package:upgrade_pilot/src/sdk/sdk_manager.dart';

/// One line of the `doctor` report.
@immutable
final class DoctorCheck {
  const DoctorCheck({
    required this.name,
    required this.status,
    required this.detail,
    this.required = false,
    this.hint,
  });

  final String name;
  final StepStatus status;
  final String detail;

  /// A failed required check makes `doctor` exit with code 3.
  final bool required;
  final String? hint;

  bool get blocking => required && status == StepStatus.failed;
}

/// `doctor`: checks the tools upgrade-pilot relies on.
final class DoctorUseCase {
  DoctorUseCase({
    required FileSystem fs,
    required HttpPort http,
    required Host host,
    required SdkManager sdkManager,
    required JdkLocator jdkLocator,
    required ToolchainProbe probe,
    required KnowledgeBase kb,
  })  : _fs = fs,
        _http = http,
        _host = host,
        _sdk = sdkManager,
        _jdk = jdkLocator,
        _probe = probe,
        _kb = kb;

  final FileSystem _fs;
  final HttpPort _http;
  final Host _host;
  final SdkManager _sdk;
  final JdkLocator _jdk;
  final ToolchainProbe _probe;
  final KnowledgeBase _kb;

  Future<List<DoctorCheck>> run({bool offline = false}) async {
    final checks = <DoctorCheck>[];
    final flutter = await _sdk.globalSdk();
    checks.add(
      flutter == null
          ? const DoctorCheck(
              name: 'Flutter',
              status: StepStatus.failed,
              detail: 'not found on PATH',
              required: true,
              hint:
                  'Install Flutter: https://docs.flutter.dev/get-started/install',
            )
          : DoctorCheck(
              name: 'Flutter',
              status: StepStatus.ok,
              detail: '${shortVersion(flutter.version)} (current project SDK)',
            ),
    );
    final git = await _probe.git();
    checks.add(
      git == null
          ? const DoctorCheck(
              name: 'git',
              status: StepStatus.warning,
              detail: 'not found',
              hint: 'apply cannot check for uncommitted changes without git',
            )
          : DoctorCheck(
              name: 'git',
              status: StepStatus.ok,
              detail: git.replaceFirst('git version ', ''),
            ),
    );
    final jdk = await _jdk.locate();
    checks.add(
      jdk == null
          ? const DoctorCheck(
              name: 'JDK',
              status: StepStatus.warning,
              detail: 'not found',
              hint: 'Android builds cannot be verified without a JDK',
            )
          : DoctorCheck(
              name: 'JDK',
              status: jdk.major >= 17 ? StepStatus.ok : StepStatus.warning,
              detail: '${jdk.version} (${jdk.origin})',
              hint: jdk.major >= 17
                  ? null
                  : 'recent Flutter versions require JDK 17+',
            ),
    );
    final android = await _probe.androidSdk();
    checks.add(
      android == null
          ? const DoctorCheck(
              name: 'Android SDK',
              status: StepStatus.warning,
              detail: 'not found',
              hint: 'Android builds will be reported as not verified',
            )
          : DoctorCheck(
              name: 'Android SDK',
              status: StepStatus.ok,
              detail: android,
            ),
    );
    if (_host.os == 'macos') {
      final xcode = await _probe.xcode();
      checks.add(
        xcode == null
            ? const DoctorCheck(
                name: 'Xcode',
                status: StepStatus.warning,
                detail: 'not found',
                hint: 'iOS builds will be reported as not verified',
              )
            : DoctorCheck(name: 'Xcode', status: StepStatus.ok, detail: xcode),
      );
      final pods = await _probe.cocoapods();
      checks.add(
        pods == null
            ? const DoctorCheck(
                name: 'CocoaPods',
                status: StepStatus.warning,
                detail: 'not found',
                hint: 'iOS projects with plugins need CocoaPods',
              )
            : DoctorCheck(
                name: 'CocoaPods',
                status: StepStatus.ok,
                detail: pods,
              ),
      );
    } else {
      checks.add(
        const DoctorCheck(
          name: 'Xcode',
          status: StepStatus.skipped,
          detail: 'macOS only: iOS builds are not verified on this machine',
        ),
      );
    }
    checks.add(await _network(offline));
    final free = await _fs.freeBytes(_host.cacheDirectory);
    checks.add(
      free == null
          ? const DoctorCheck(
              name: 'Disk',
              status: StepStatus.skipped,
              detail: 'free space unknown on this platform',
            )
          : DoctorCheck(
              name: 'Disk',
              status: free >= SdkManager.requiredBytes
                  ? StepStatus.ok
                  : StepStatus.warning,
              detail:
                  '${(free / (1 << 30)).toStringAsFixed(1)} GB free in cache',
              hint: free >= SdkManager.requiredBytes
                  ? null
                  : 'downloading a Flutter SDK needs about 4 GB',
            ),
    );
    return checks
      ..add(
        DoctorCheck(
          name: 'Knowledge base',
          status: StepStatus.ok,
          detail: '${_kb.kbVersion} · ${_kb.flutter.length} Flutter releases · '
              'sha256 ${_kb.sha256.substring(0, 12)}',
        ),
      );
  }

  Future<DoctorCheck> _network(bool offline) async {
    if (offline) {
      return const DoctorCheck(
        name: 'Network',
        status: StepStatus.skipped,
        detail: 'offline mode',
      );
    }
    try {
      final reply = await _http.get(
        Uri.parse('https://pub.dev/api/packages/pub_semver'),
      );
      return DoctorCheck(
        name: 'Network',
        status: reply.ok ? StepStatus.ok : StepStatus.warning,
        detail: reply.ok
            ? 'pub.dev reachable'
            : 'pub.dev answered ${reply.statusCode}',
      );
    } on NetworkException catch (e) {
      return DoctorCheck(
        name: 'Network',
        status: StepStatus.warning,
        detail: 'pub.dev unreachable (${e.message})',
        hint: 'use --offline with cached data',
      );
    }
  }
}
