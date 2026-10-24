import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-256 of [content] (UTF-8), hex encoded.
String sha256Hex(String content) =>
    sha256.convert(utf8.encode(content)).toString();
