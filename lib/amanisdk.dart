import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:amani_flutter_sdk/sdkresult.dart';
import 'package:flutter/services.dart';
import 'amaniAndroidConfigure.dart';
import 'amani_security.dart';
import 'amanisdk_platform_interface.dart';

class Amanisdk {
  Completer<SdkResult>? _completer;

  /// Starts a KYC session. Only one session may be active at a time: a second
  /// call would silently replace the completer of the first one and leave its
  /// future hanging forever.
  Future<SdkResult> _runSession(Future<void> Function() launch) async {
    if (_completer != null && !_completer!.isCompleted) {
      throw StateError('An Amani KYC session is already in progress');
    }
    final completer = Completer<SdkResult>();
    _completer = completer;
    try {
      await launch();
    } catch (e) {
      // Native side rejected the call (PlatformException etc.): surface it
      // to the caller instead of leaving an unawaited, never-completing future.
      if (identical(_completer, completer)) _completer = null;
      rethrow;
    }
    return completer.future;
  }

  Amanisdk() {
    AmanisdkPlatform.instance.methodChannel
        .setMethodCallHandler(_handleInverseChannel);
  }

  /// Starts our native android or ios sdk.
  /// [server], [token], and [id] fields are required.
  ///
  /// [birthDate], [expireDate] and [documentNo] fields are grouped optionals so
  /// you must use all of them if you use one of them.
  ///
  /// Any *date* format is in **YYMMDD** format.
  ///
  /// [email], [phone], [name] fields are related to customer profile.
  ///
  ///
  ///
  ///

  // Future<void> setConfigure({
  //   required String server,
  //   List<AmaniAndroidDynamicFeature> enabledFeatures = const [],
  // }) async {
  //   await AmanisdkPlatform.instance.setConfigure(
  //     server: server,
  //     enabledFeatures: enabledFeatures.map((e) => e.name).toList(),
  //   );
  //   // _isConfigured = true;
  // }

  Future<void> setConfigure({
    required String server,
    List<AmaniAndroidDynamicFeature> enabledFeatures = const [],
    String? sharedSecret,
    AmaniUploadSource uploadSource = AmaniUploadSource.kyc,
  }) async {
    // NOTE: [sharedSecret] ships inside the channel payload and, if it is
    // hard-coded in the app, inside the app binary. Prefer fetching it at
    // runtime from your backend / secure storage; never commit it.
    server = AmaniSecurity.validateServer(server);
    await AmanisdkPlatform.instance.setConfigure(
      server: server,
      enabledFeatures: enabledFeatures.map((e) => e.name).toList(),
      sharedSecret: sharedSecret,
      uploadSource: uploadSource.getUploadSourceString,
    );
  }

  Future<SdkResult> startAmaniSDKWithConfigure({
    required String token,
    required String id,
    String? birthDate,
    String? expireDate,
    String? documentNo,
    bool geoLocation = false,
    String? lang,
    String? email,
    String? phone,
    String? name,
  }) async {
    if (token.isEmpty) {
      throw Exception("You can't use an empty string as token");
    }
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty');
    }

    final payloadJson = AmaniSecurity.decodeJwtPayload(token);
    AmaniSecurity.ensureNotExpired(payloadJson);

    if (payloadJson['profile_id'] == null &&
        payloadJson['customer_id'] == null) {
      throw Exception("You can't use admin token with this SDK.");
    }

    AmaniSecurity.validateNviGroup(birthDate, expireDate, documentNo);
    final language = AmaniSecurity.validateLang(lang, fallback: 'en');

    return _runSession(
        () => AmanisdkPlatform.instance.startAmaniSDKWithConfigure(
              token,
              id,
              birthDate,
              expireDate,
              documentNo,
              geoLocation,
              language,
              email,
              phone,
              name,
            ));
  }

  Future<SdkResult> startAmaniSDKWithToken({
    required String server,
    required String token,
    required String id,
    String? birthDate,
    String? expireDate,
    String? documentNo,
    bool? geoLocation,
    String? lang,
    String? email,
    String? phone,
    String? name,
  }) async {
    server = AmaniSecurity.validateServer(server);
    final String language = AmaniSecurity.validateLang(lang);
    final bool location = geoLocation ?? false;
    String apiVersion = 'v2';

    if (token.isEmpty) {
      throw Exception("You can't use an empty string as token");
    }
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty');
    }

    // Parse the JWT token and check if payload contains customer_id
    final payloadJson = AmaniSecurity.decodeJwtPayload(token);
    AmaniSecurity.ensureNotExpired(payloadJson);

    if (payloadJson['customer_id'] != null) {
      apiVersion = 'v1';
    } else if (payloadJson['profile_id'] == null) {
      throw Exception("You can't use admin token with this SDK.");
    }

    AmaniSecurity.validateNviGroup(birthDate, expireDate, documentNo);

    // Enjoy the ride.
    return _runSession(() => AmanisdkPlatform.instance.startAmaniSDKWithToken(
          server,
          token,
          id,
          birthDate,
          expireDate,
          documentNo,
          location,
          language,
          email,
          phone,
          name,
          apiVersion,
        ));
  }

  Future<void> _handleInverseChannel(MethodCall call) async {
    final completer = _completer;
    if (completer == null || completer.isCompleted) return;
    try {
      switch (call.method) {
        case 'onSuccess':
          final args = call.arguments;
          if (args is! String) {
            throw const FormatException('Unexpected result payload');
          }
          final result = SdkResult.fromJson(jsonDecode(args));
          _completer = null;
          completer.complete(result);
          break;
        case 'onError':
          _completer = null;
          completer.completeError(call.arguments);
          break;
      }
    } catch (e) {
      // A malformed native payload must never leave the caller hanging.
      _completer = null;
      completer.completeError(e);
    }
  }

  /// Deprecated: sends a login e-mail and password through the platform
  /// channel and is not implemented on Android. Authenticate on your backend
  /// and use [startAmaniSDKWithToken] with a short-lived, profile-scoped token.
  @Deprecated('Use startAmaniSDKWithToken with a backend-issued token.')
  Future<SdkResult> startAmaniSDKWithCredentials({
    required String server,
    required String loginEmail,
    required String loginPassword,
    required String id,
    String? birthDate,
    String? expireDate,
    String? documentNo,
    bool? geoLocation,
    String? lang,
    String? email,
    String? phone,
    String? name,
  }) async {
    server = AmaniSecurity.validateServer(server);
    // Adds the suffix for api endpoints.
    String serverURL = Platform.isAndroid ? '$server/api/v2/' : server;
    String language = AmaniSecurity.validateLang(lang);
    bool location = geoLocation ?? false;
    AmaniSecurity.validateNviGroup(birthDate, expireDate, documentNo);

    return _runSession(() => AmanisdkPlatform.instance
        .startAmaniSDKWithCredentials(
            serverURL,
            loginEmail,
            loginPassword,
            id,
            birthDate,
            expireDate,
            documentNo,
            location,
            language,
            email,
            phone,
            name));
  }

  /// Pins the server certificate (iOS only). [certificate] is a local file
  /// path or `file://` URL of the `.cer` file.
  ///
  /// Throws a [PlatformException] if pinning could not be applied, so the
  /// app never silently continues without pinning.
  Future<void> setSSLPinning(
    String? certificate,
  ) async {
    if (certificate == null || certificate.trim().isEmpty) {
      throw ArgumentError.value(
          certificate, 'certificate', 'Must not be empty');
    }
    await AmanisdkPlatform.instance.setSSLPinning(certificate);
  }
}
