class SdkResult {
  bool isVerificationCompleted;
  bool isTokenExpired;

  /// Due to differences in our iOS SDK this field always will be *nil* on iOS.
  /// Use it with Platform Check.
  ///
  /// On Android 1000 is the default value.
  int? apiExceptionCode;

  /// This field indicates there is an network error that should show up an
  /// error popup on your applications side
  bool? networkError;

  /// Filled if the user canceled the KYC process or failed the verification.
  /// Android sends a `Map`, iOS sends a `List` of rules, hence `dynamic`.
  dynamic rules;

  SdkResult(this.isVerificationCompleted, this.isTokenExpired,
      this.apiExceptionCode, this.networkError, this.rules);

  factory SdkResult.fromJson(dynamic json) {
    return SdkResult(
        json['isVerificationCompleted'] == true,
        json['isTokenExpired'] == true,
        json['apiExceptionCode'] is int
            ? json['apiExceptionCode'] as int
            : null,
        json['networkError'] == true,
        json['rules']);
  }
}
