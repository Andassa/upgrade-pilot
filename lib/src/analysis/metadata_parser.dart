import 'dart:convert';

import 'package:upgrade_pilot/src/domain/project_snapshot.dart';
import 'package:yaml/yaml.dart';

/// Reads the Flutter version pinned by FVM in `.fvmrc`.
FlutterPin? parseFvmrc(String content) {
  final json = _jsonMap(content);
  final version = json?['flutter'] ?? json?['flutterSdkVersion'];
  if (version is! String) return null;
  return FlutterPin(source: FlutterPinSource.fvmrc, version: version);
}

/// Reads the legacy FVM file `.fvm/fvm_config.json`.
FlutterPin? parseFvmConfig(String content) {
  final version = _jsonMap(content)?['flutterSdkVersion'];
  if (version is! String) return null;
  return FlutterPin(source: FlutterPinSource.fvmConfig, version: version);
}

/// Reads the framework revision and channel recorded in `.metadata`.
FlutterPin? parseMetadata(String content) {
  final Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException {
    return null;
  }
  if (doc is! YamlMap) return null;
  final version = doc['version'];
  if (version is! YamlMap) return null;
  final revision = version['revision'];
  final channel = version['channel'];
  return FlutterPin(
    source: FlutterPinSource.metadata,
    version: channel is String ? channel : null,
    revision: revision is String ? revision : null,
  );
}

Map<String, Object?>? _jsonMap(String content) {
  try {
    final decoded = jsonDecode(content);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}
