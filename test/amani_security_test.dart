import 'dart:convert';

import 'package:amani_flutter_sdk/amani_security.dart';
import 'package:flutter_test/flutter_test.dart';

String _jwt(Map<String, dynamic> payload) {
  String enc(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'none'})}.${enc(payload)}.sig';
}

void main() {
  group('validateServer', () {
    test('accepts https', () {
      expect(AmaniSecurity.validateServer('https://x.amani.ai'),
          'https://x.amani.ai');
    });
    test('rejects http unless insecure allowed', () {
      expect(
          () => AmaniSecurity.validateServer('http://x.amani.ai',
              allowInsecure: false),
          throwsArgumentError);
      expect(
          AmaniSecurity.validateServer('http://x.amani.ai',
              allowInsecure: true),
          'http://x.amani.ai');
    });
    test('rejects other schemes, userinfo and relative urls', () {
      for (final bad in [
        'ftp://x.com',
        'https://u:p@x.com',
        'x.com',
        '',
        'javascript:alert(1)'
      ]) {
        expect(() => AmaniSecurity.validateServer(bad), throwsArgumentError,
            reason: bad);
      }
    });
  });

  group('jwt', () {
    test('decodes payload', () {
      expect(
          AmaniSecurity.decodeJwtPayload(_jwt({'profile_id': 1}))['profile_id'],
          1);
    });
    test('malformed tokens throw FormatException', () {
      for (final bad in ['a.b', 'a..c', 'a.!!!.c', '...', 'abc']) {
        expect(() => AmaniSecurity.decodeJwtPayload(bad), throwsFormatException,
            reason: bad);
      }
    });
    test('expired token rejected, valid and exp-less accepted', () {
      final now = DateTime.utc(2026, 1, 1);
      final past = now.millisecondsSinceEpoch ~/ 1000 - 3600;
      final future = now.millisecondsSinceEpoch ~/ 1000 + 3600;
      expect(() => AmaniSecurity.ensureNotExpired({'exp': past}, now: now),
          throwsException);
      AmaniSecurity.ensureNotExpired({'exp': future}, now: now);
      AmaniSecurity.ensureNotExpired({}, now: now);
    });
  });

  group('misc validation', () {
    test('lang', () {
      expect(AmaniSecurity.validateLang('pt-BR'), 'pt-BR');
      expect(AmaniSecurity.validateLang(null), 'tr');
      expect(() => AmaniSecurity.validateLang('en;drop'), throwsArgumentError);
    });
    test('nvi group', () {
      AmaniSecurity.validateNviGroup(null, null, null);
      AmaniSecurity.validateNviGroup('900101', '300101', 'A123');
      expect(() => AmaniSecurity.validateNviGroup('900101', null, null),
          throwsArgumentError);
      expect(() => AmaniSecurity.validateNviGroup('1990', '300101', 'A'),
          throwsArgumentError);
    });
  });
}
