import Flutter
import UIKit
import AmaniUI
import AmaniSDK

@objc
public class SwiftAmanisdkPlugin: NSObject, FlutterPlugin {
  let nativeSDK = AmaniUI.sharedInstance
  var channel: FlutterMethodChannel?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: "amanisdk", binaryMessenger: registrar.messenger())
    let instance = SwiftAmanisdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    instance.channel = methodChannel
  }
  
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startAmaniSDKWithToken":
      startAmaniSDKWithToken(call: call, result: result)
    case "startAmaniSDKWithCredentials":
      startAmaniSDKWithCredentials(call: call, result: result)
    case "SSLcertificate":
      setSSLPinning(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Validation helpers

  private func invalidArgument(_ result: FlutterResult, _ message: String) {
    result(FlutterError(code: "INVALID_ARGUMENT", message: message, details: nil))
  }

  /// Absolute https URL without embedded credentials. Cleartext http is only
  /// tolerated in DEBUG builds (local development servers).
  private func isAllowedServer(_ server: String) -> Bool {
    guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil else { return false }
    if scheme == "https" { return true }
    #if DEBUG
    return scheme == "http"
    #else
    return false
    #endif
  }

  private func nonEmpty(_ value: Any?) -> String? {
    guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
  }

  private func buildCustomer(_ params: [String: Any], id: String) -> CustomerRequestModel {
    let name = params["name"] as? String
    let email = params["email"] as? String
    let phone = params["phone"] as? String
    if name == nil && email == nil && phone == nil {
      return CustomerRequestModel(idCardNumber: id)
    }
    return CustomerRequestModel(name: name, email: email, phone: phone, idCardNumber: id)
  }

  private func buildNvi(_ params: [String: Any]) -> NviModel? {
    guard let birthDate = params["birthDate"] as? String,
          let expireDate = params["expireDate"] as? String,
          let documentNo = params["documentNo"] as? String else { return nil }
    return NviModel(documentNo: documentNo, dateOfBirth: birthDate, dateOfExpire: expireDate)
  }

  // MARK: - SSL pinning

  /// Applies certificate pinning. Failures are reported to Flutter instead of
  /// being swallowed: a silently ignored pinning error means traffic is NOT
  /// pinned while the app believes it is.
  func setSSLPinning(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let params = call.arguments as? [String: Any],
          let certificate = nonEmpty(params["certificate"]) else {
      invalidArgument(result, "'certificate' must be a non-empty path")
      return
    }
    let certURL: URL
    if certificate.hasPrefix("file://"), let u = URL(string: certificate) {
      certURL = u
    } else if certificate.hasPrefix("/") {
      certURL = URL(fileURLWithPath: certificate)
    } else {
      invalidArgument(result, "'certificate' must be a local file path")
      return
    }
    guard FileManager.default.isReadableFile(atPath: certURL.path) else {
      invalidArgument(result, "Certificate file is not readable")
      return
    }
    Task {
      do {
        try await self.nativeSDK.setSSLPinning(certificate: certURL)
        result(nil)
      } catch {
        result(FlutterError(code: "SSL_PINNING_FAILED", message: "SSL pinning could not be applied", details: nil))
      }
    }
  }

  // MARK: - Start

  func startAmaniSDKWithToken(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let params = call.arguments as? [String: Any],
          let server = nonEmpty(params["server"]),
          let token = nonEmpty(params["token"]),
          let id = nonEmpty(params["id"]) else {
      invalidArgument(result, "'server', 'token' and 'id' are required")
      return
    }
    guard isAllowedServer(server) else {
      invalidArgument(result, "'server' must be an https URL")
      return
    }

    let apiVersion: ApiVersions = (params["apiVersion"] as? String) == "v1" ? .v1 : .v2
    let customer = buildCustomer(params, id: id)
    let nvi = buildNvi(params)
    let language = params["lang"] as? String ?? "tr"

    DispatchQueue.main.async {
      guard let vc = self.topMostViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No view controller to present from", details: nil))
        return
      }
      self.nativeSDK.setDelegate(delegate: self)
      self.nativeSDK.set(
        server: server,
        token: token,
        customer: customer,
        language: language,
        nviModel: nvi,
        apiVersion: apiVersion
      )
      self.nativeSDK.showSDK(on: vc) { (customerModel, error) in
        // no-op
      }
      result(nil)
    }
  }

  func startAmaniSDKWithCredentials(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let params = call.arguments as? [String: Any],
          let server = nonEmpty(params["server"]),
          let loginEmail = nonEmpty(params["loginEmail"]),
          let loginPassword = nonEmpty(params["loginPassword"]),
          let id = nonEmpty(params["id"]) else {
      invalidArgument(result, "'server', 'loginEmail', 'loginPassword' and 'id' are required")
      return
    }
    guard isAllowedServer(server) else {
      invalidArgument(result, "'server' must be an https URL")
      return
    }
    let customer = buildCustomer(params, id: id)
    let nvi = buildNvi(params)
    let language = params["lang"] as? String ?? "tr"

    DispatchQueue.main.async {
      guard let vc = self.topMostViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No view controller to present from", details: nil))
        return
      }
      self.nativeSDK.setDelegate(delegate: self)
      self.nativeSDK.set(
        server: server,
        userName: loginEmail,
        password: loginPassword,
        customer: customer,
        language: language,
        nviModel: nvi,
        apiVersion: .v2
      )
      self.nativeSDK.showSDK(on: vc) { (customerRes, error) in
        // no-op
      }
      result(nil)
    }
  }

  /// Top-most presented view controller of the active foreground scene.
  /// Replaces the deprecated `UIApplication.windows.last` lookup, which could
  /// pick an overlay window (e.g. keyboard / alert) or crash on force unwrap.
  private func topMostViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  /// Platform channel calls must happen on the main thread; native SDK
  /// delegates may call back from any queue.
  fileprivate func send(_ method: String, _ payload: [String: Any]) {
    let json = resultToJson(dictionary: payload)
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: json)
    }
  }

  /// Always returns valid JSON, so the Dart side can decode it.
  fileprivate func resultToJson(dictionary: [String: Any]) -> String {
    let fallback = "{\"isVerificationCompleted\":false,\"isTokenExpired\":false}"
    guard JSONSerialization.isValidJSONObject(dictionary),
          let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return fallback
    }
    return json
  }

}


extension SwiftAmanisdkPlugin: AmaniUIDelegate {
  public func onKYCSuccess(CustomerId: String) {
    let resultData: [String: Any] = [
      "isVerificationCompleted": true,
      "isTokenExpired": false,
    ]
    send("onSuccess", resultData)
    
  }
  
  public func onKYCFailed(CustomerId: String, Rules: [[String : String]]?) {
    let resultData: [String: Any] = [
      "isVerificationCompleted": false,
      "isTokenExpired": false,
      "rules": Rules ?? []
    ]
    send("onSuccess", resultData)
  }

  public func onError(type:String,Error:[AmaniError]){
    
    let rulesArray: [[String: Any]] = Error.map { err in
      return [
        "error_code": err.error_code ?? 0,
        "error_message": err.error_message ?? ""
      ]
    }
    
    let resultData: [String:Any] = [
      "isVerificationCompleted": false,
      "isTokenExpired": false,
      "rules": rulesArray
    ]
    
    send("onError", resultData)
  }

  
}

