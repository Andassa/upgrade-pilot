import 'package:path/path.dart' as p;

/// Variables passed to Flutter, Gradle and CocoaPods. Everything else
/// (tokens, cloud credentials...) is dropped.
const environmentAllowList = {
  'HOME',
  'USER',
  'LOGNAME',
  'SHELL',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TMPDIR',
  'TEMP',
  'TMP',
  'JAVA_HOME',
  'ANDROID_HOME',
  'ANDROID_SDK_ROOT',
  'ANDROID_NDK_HOME',
  'ANDROID_USER_HOME',
  'GRADLE_USER_HOME',
  'PUB_CACHE',
  'PUB_HOSTED_URL',
  'FLUTTER_STORAGE_BASE_URL',
  'XDG_CACHE_HOME',
  'XDG_CONFIG_HOME',
  'DEVELOPER_DIR',
  'SSL_CERT_FILE',
  'SSL_CERT_DIR',
  'http_proxy',
  'https_proxy',
  'no_proxy',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'NO_PROXY',
  'GEM_HOME',
  'GEM_PATH',
  // Windows essentials.
  'SystemRoot',
  'SystemDrive',
  'windir',
  'ComSpec',
  'PATHEXT',
  'USERPROFILE',
  'APPDATA',
  'LOCALAPPDATA',
  'ProgramData',
  'ProgramFiles',
  'ProgramFiles(x86)',
  'NUMBER_OF_PROCESSORS',
  'PROCESSOR_ARCHITECTURE',
};

/// The environment of child processes: allow-listed variables, the
/// target SDK first on `PATH`, analytics off. The user's own `PATH` is
/// not modified; only the child sees this one.
Map<String, String> childEnvironment(
  Map<String, String> host,
  String sdkRoot, {
  required bool windows,
}) {
  final pathKey = windows && host.containsKey('Path') ? 'Path' : 'PATH';
  final separator = windows ? ';' : ':';
  final sdkBin = p.join(sdkRoot, 'bin');
  final inherited = (host[pathKey] ?? '')
      .split(separator)
      .where((e) => e.isNotEmpty && !_isFlutterBin(e))
      .join(separator);
  return {
    for (final MapEntry(:key, :value) in host.entries)
      if (environmentAllowList.contains(key)) key: value,
    pathKey: inherited.isEmpty ? sdkBin : '$sdkBin$separator$inherited',
    'FLUTTER_SUPPRESS_ANALYTICS': 'true',
    'DART_SUPPRESS_ANALYTICS': 'true',
    'PUB_ENVIRONMENT': 'upgrade_pilot',
  };
}

/// Other Flutter SDKs on the PATH would shadow the target one.
bool _isFlutterBin(String entry) {
  final normalized = entry.replaceAll(r'\', '/');
  return normalized.endsWith('/flutter/bin') ||
      normalized.endsWith('/flutter/bin/');
}
