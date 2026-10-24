import 'package:path/path.dart' as p;

/// Decides what is copied into the sandbox and what can be diffed.
abstract final class CopyPolicy {
  /// Directory names never copied: build outputs, caches, VCS data.
  static const excludedDirectories = {
    'build',
    '.dart_tool',
    '.git',
    '.hg',
    '.svn',
    '.idea',
    '.vscode',
    '.gradle',
    '.kotlin',
    '.cxx',
    'Pods',
    '.symlinks',
    'ephemeral',
    '.upgrade-pilot',
    'node_modules',
    '.fvm',
    'DerivedData',
    'xcuserdata',
  };

  static final _secretPatterns = [
    RegExp(
      r'\.(jks|keystore|p12|pfx|pem|key|p8|cer|der|crt|mobileprovision|provisionprofile|gpg|asc)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^(key|keystore|signing|secrets?)\.properties$',
      caseSensitive: false,
    ),
    RegExp(r'^\.env(\..*)?$'),
    RegExp(r'^(\.netrc|\.npmrc|\.pypirc|id_rsa.*|id_ed25519.*)$'),
    RegExp(r'service[-_]?account.*\.json$', caseSensitive: false),
  ];

  /// Signing material and credentials: never copied, never read.
  static bool isSecret(String fileName) =>
      _secretPatterns.any((r) => r.hasMatch(fileName));

  /// Machine-specific files that Flutter regenerates.
  static const _machineFiles = {
    'local.properties',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    'Generated.xcconfig',
    'flutter_export_environment.sh',
  };

  static bool isMachineFile(String fileName) =>
      _machineFiles.contains(fileName) || fileName.endsWith('.iml');

  static const _trackedExtensions = {
    '.yaml',
    '.yml',
    '.lock',
    '.gradle',
    '.kts',
    '.properties',
    '.toml',
    '.xml',
    '.plist',
    '.pbxproj',
    '.xcscheme',
    '.xcworkspacedata',
    '.xcconfig',
    '.swift',
    '.m',
    '.h',
    '.kt',
    '.java',
  };

  static const _trackedNames = {'Podfile', 'Gemfile', '.metadata', '.fvmrc'};

  /// Text files whose changes become part of the plan.
  static bool isTracked(String relativePath) {
    final name = p.posix.basename(relativePath);
    if (name.startsWith('GeneratedPluginRegistrant')) return false;
    return _trackedNames.contains(name) ||
        _trackedExtensions.contains(p.posix.extension(name));
  }

  /// New files (absent from the project) that are kept in the plan.
  static const keptNewFiles = {
    'pubspec.lock',
    'android/gradle.properties',
    'android/gradle/wrapper/gradle-wrapper.properties',
    'ios/Podfile',
    'ios/Podfile.lock',
  };

  /// Files produced by tools rather than written by hand.
  static bool isGenerated(String relativePath) =>
      relativePath.endsWith('pubspec.lock') ||
      relativePath.endsWith('Podfile.lock');

  static const int maxTrackedBytes = 2 * 1024 * 1024;
}
