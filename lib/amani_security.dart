import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Input validation helpers used by the bridge before any value crosses the
/// platform channel. Native code re-validates the critical ones (defense in
/// depth), but failing early in Dart gives integrators a clear error.
class AmaniSecurity {
  AmaniSecurity._();

  static final RegExp _langPattern =
      RegExp(r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8}){0,2}$');
  static final RegExp _datePattern = RegExp(r'^\d{6}$');

  /// Clock skew tolerated when checking `exp` (seconds).
  static const int _clockSkewSeconds = 60;

  /// Ensures the server URL is an absolute `https` URL without embedded
  /// credentials. Plain `http` is accepted only in debug builds so that local
  /// development servers keep working.
  static String validateServer(String server, {bool? allowInsecure}) {
    final trimmed = server.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(server, 'server', 'Must be an absolute URL');
    }
    if (uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(
          server, 'server', 'Credentials in the URL are not allowed');
    }
    final scheme = uri.scheme.toLowerCase();
    final insecureOk = allowInsecure ?? kDebugMode;
    if (scheme != 'https' && !(scheme == 'http' && insecureOk)) {
      throw ArgumentError.value(
          server, 'server', 'Only https:// servers are allowed');
    }
    return trimmed;
  }

  /// Decodes the JWT payload without verifying the signature (the signature
  /// can only be verified by the backend). Throws [FormatException] for any
  /// malformed token instead of leaking `RangeError`/`TypeError`.
  static Map<String, dynamic> decodeJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
      throw const FormatException('The token must be in JWT format');
    }
    try {
      final payload = utf8.decode(base64Url.decode(base64.normalize(parts[1])));
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Invalid JWT payload');
      }
      return json;
    } on FormatException {
      throw const FormatException('Invalid JWT token format');
    }
  }

  /// Throws if the token carries an `exp` claim that is already in the past.
  /// This is a convenience check (fail fast, no useless network round trip);
  /// the backend remains the authority.
  static void ensureNotExpired(Map<String, dynamic> payload, {DateTime? now}) {
    final exp = payload['exp'];
    if (exp is num) {
      final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
      if (exp.toInt() + _clockSkewSeconds < nowSeconds) {
        throw Exception('The token has expired');
      }
    }
  }

  /// Validates an optional `YYMMDD` date.
  static String? validateDate(String? value, String name) {
    if (value == null) return null;
    if (!_datePattern.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'Must be in YYMMDD format');
    }
    return value;
  }

  /// Validates a language tag such as `tr`, `en` or `pt-BR`.
  static String validateLang(String? lang, {String fallback = 'tr'}) {
    final value = lang ?? fallback;
    if (!_langPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'lang', 'Invalid language code');
    }
    return value;
  }

  /// `birthDate`, `expireDate` and `documentNo` are a group: all or none.
  static void validateNviGroup(
      String? birthDate, String? expireDate, String? documentNo) {
    final set = [birthDate, expireDate, documentNo].where((e) => e != null);
    if (set.isNotEmpty && set.length != 3) {
      throw ArgumentError(
          'birthDate, expireDate and documentNo must be provided together');
    }
    validateDate(birthDate, 'birthDate');
    validateDate(expireDate, 'expireDate');
  }
}
