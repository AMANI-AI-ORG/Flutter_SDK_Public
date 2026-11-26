package ai.amani.amanisdk

import AmaniSDKUI
import ai.amani.base.util.SessionManager
import ai.amani.base.utility.AmaniVersion
import ai.amani.base.utility.AppConstants
import ai.amani.sdk.model.KYCResult
import ai.amani.sdk.utils.AppConstant
import ai.amani.sdk.utils.ProfileStatus
import ai.amani.sdk.DynamicFeature
import ai.amani.sdk.UploadSource
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import java.util.Locale
import androidx.activity.result.contract.ActivityResultContracts
import com.google.gson.JsonObject
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** AmanisdkPlugin  */
class AmanisdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    /// The MethodChannel that will the communication between Flutter and native Android
    ///
    /// This local reference serves to register the plugin with the Flutter Engine and unregister it
    /// when the Flutter Engine is detached from the Activity
    private var channel: MethodChannel? = null
    private var currentActivity: Activity? = null
    private var currentContext: Context? = null
    private var resultLauncher: ActivityResultLauncher<Intent>? = null
    private var isConfigured: Boolean = false

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        currentContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "amanisdk").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAmaniSDKWithToken" -> startAmaniSDKWithToken(call, result)
            "setConfigure" -> setConfigure(call, result)
            "startAmaniSDKWithConfigure" -> startAmaniSDKWithConfigure(call, result)
            // Credential based login is intentionally not supported on Android:
            // passwords must not travel through the platform channel.
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        currentContext = null
        isConfigured = false
    }

    // Gets currentActivity to pass startKYCProcess
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun attachActivity(activity: Activity) {
        currentActivity = activity
        // Host must extend FlutterFragmentActivity (a ComponentActivity). Do not
        // hard-cast: a plain FlutterActivity would crash the whole app here.
        val componentActivity = activity as? ComponentActivity
        if (componentActivity == null) {
            Log.e(TAG, "Host activity must extend FlutterFragmentActivity")
            resultLauncher = null
            return
        }
        resultLauncher = componentActivity.registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result -> handleKycResult(result.resultCode, result.data) }
    }

    private fun detachActivity() {
        // Drop the Activity reference to avoid leaking it past its lifecycle.
        resultLauncher?.unregister()
        resultLauncher = null
        currentActivity = null
    }

    private fun handleKycResult(resultCode: Int, data: Intent?) {
        val resultMap = JsonObject()
        try {
            val kycResult: KYCResult? =
                if (resultCode == Activity.RESULT_OK) data?.parcelable(AppConstant.KYC_RESULT) else null
            if (kycResult != null) {
                resultMap.addProperty(
                    "isVerificationCompleted",
                    kycResult.profileStatus == ProfileStatus.APPROVED
                )
                resultMap.addProperty("isTokenExpired", kycResult.errorCode == 403)
                resultMap.addProperty("apiExceptionCode", kycResult.errorCode)
            } else {
                // Cancelled / no result: always answer so the Dart future completes.
                resultMap.addProperty("isVerificationCompleted", false)
                resultMap.addProperty("isTokenExpired", false)
                resultMap.addProperty("apiExceptionCode", 1000)
            }
            channel?.invokeMethod("onSuccess", resultMap.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to deliver KYC result", e)
            channel?.invokeMethod("onError", "Error happened while returning the result")
        }
    }

    /**
     * Server must be an absolute https URL with no embedded credentials.
     * Cleartext http is tolerated only for debuggable apps (local dev servers).
     */
    private fun isAllowedServer(context: Context, server: String): Boolean {
        val uri = try { Uri.parse(server.trim()) } catch (e: Exception) { return false }
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return false
        if (uri.host.isNullOrBlank() || !uri.userInfo.isNullOrEmpty()) return false
        if (scheme == "https") return true
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        return scheme == "http" && debuggable
    }

    private fun setConfigure(call: MethodCall, result: MethodChannel.Result) {
    val context = currentContext
    if (context == null) {
        result.error("NO_CONTEXT", "Current context is null. Plugin is not attached to engine.", null)
        return
    }

    val server = call.argument<String>("server")
    if (server.isNullOrBlank()) {
        result.error("INVALID_ARGUMENT", "Argument 'server' must not be null or empty.", null)
        return
    }
    if (!isAllowedServer(context, server)) {
        result.error("INVALID_ARGUMENT", "Argument 'server' must be an https URL.", null)
        return
    }

   
    val features = call.argument<List<String>>("enabledFeatures") ?: emptyList()

    val dynamicFeatures = features.mapNotNull { featureName ->
        when (featureName) {
            "idCapture" -> DynamicFeature.ID_CAPTURE
            "idHologramDetection" -> DynamicFeature.ID_HOLOGRAM_DETECTION
            "nfcScan" -> DynamicFeature.NFC_SCAN
            "selfieAuto" -> DynamicFeature.SELFIE_AUTO
            "selfiePoseEstimation" -> DynamicFeature.SELFIE_POSE_ESTIMATION
            else -> null 
        }
    }

    
    val sharedSecret = call.argument<String>("sharedSecret")
    val uploadSourceString = call.argument<String>("uploadSource")
    val uploadSource = when (uploadSourceString) {
        "VIDEO" -> UploadSource.VIDEO
        "PASSWORD" -> UploadSource.PASSWORD
        "KYC", null -> UploadSource.KYC
        else -> UploadSource.KYC
    }

    val apiVersionString = call.argument<String>("apiVersion")
    val amaniVersion = when (apiVersionString) {
        "v1" -> AmaniVersion.V1
        "v2", null -> AmaniVersion.V2
        else -> AmaniVersion.V2
    }

    try {
        AmaniSDKUI.configure(
            applicationContext = context,
            serverURL = server,
            sharedSecret = sharedSecret,          
            amaniVersion = amaniVersion,
            uploadSource = uploadSource,
            enabledFeatures = dynamicFeatures    
        )
        isConfigured = true
        result.success(null)
    } catch (e: Exception) {
        Log.e(TAG, "configure failed", e)
        result.error("CONFIGURE_FAILED", "AmaniSDKUI.configure failed", null)
    }
}

private fun startAmaniSDKWithConfigure(call: MethodCall, result: MethodChannel.Result) {
    if (!isConfigured) {
        result.error(
            "NOT_CONFIGURED",
            "AmaniSDKUI is not configured. Call 'setConfigure' before starting KYC.",
            null
        )
        return
    }

    val activity = currentActivity
    val launcher = resultLauncher

    if (activity == null || launcher == null) {
        result.error(
            "NO_ACTIVITY",
            "Current Activity or resultLauncher is null.",
            null
        )
        return
    }

    val componentActivity = activity as? ComponentActivity
    if (componentActivity == null) {
        result.error(
            "INVALID_ACTIVITY",
            "Current Activity must be a ComponentActivity.",
            null
        )
        return
    }

    val idNumber = call.argument<String>("id")
    val token = call.argument<String>("token")

    if (idNumber.isNullOrBlank() || token.isNullOrBlank()) {
        result.error(
            "INVALID_ARGUMENT",
            "Arguments 'id' and 'token' must not be null or empty.",
            null
        )
        return
    }

    val birthDate = call.argument<String>("birthDate")
    val expireDate = call.argument<String>("expireDate")
    val documentNo = call.argument<String>("documentNo")

    val geoLocation = call.argument<Boolean>("geoLocation") ?: false
    val lang = call.argument<String>("lang")
        ?: call.argument<String>("language")
        ?: "en"

    val email = call.argument<String>("email")
    val phone = call.argument<String>("phone")
    val name = call.argument<String>("name")

    try {
        AmaniSDKUI.goToKycActivity(
            activity = componentActivity,
            resultLauncher = launcher,
            idNumber = idNumber,
            authToken = token,
            language = lang,
            geoLocation = geoLocation,
            birthDate = birthDate,
            expireDate = expireDate,
            documentNumber = documentNo,
            userEmail = email,
            userPhoneNumber = phone,
            userFullName = name
        )
        result.success(null)
    } catch (e: Exception) {
        Log.e(TAG, "Failed to start KYC activity", e)
        result.error("START_KYC_FAILED", "Failed to start KYC activity", null)
    }
}



   private fun startAmaniSDKWithToken(call: MethodCall, result: MethodChannel.Result) {
    val activity = currentActivity
    val launcher = resultLauncher

    if (activity == null || launcher == null) {
        result.error(
            "NO_ACTIVITY",
            "Current Activity or resultLauncher is null.",
            null
        )
        return
    }

    val componentActivity = activity as? ComponentActivity
    if (componentActivity == null) {
        result.error(
            "INVALID_ACTIVITY",
            "Current Activity must be a ComponentActivity.",
            null
        )
        return
    }

    val context = currentContext ?: activity.applicationContext

    val server = call.argument<String>("server")
    val token = call.argument<String>("token")
    val idNumber = call.argument<String>("id")

    if (server.isNullOrBlank()) {
        result.error(
            "INVALID_ARGUMENT",
            "Argument 'server' must not be null or empty.",
            null
        )
        return
    }

    if (!isAllowedServer(context, server)) {
        result.error(
            "INVALID_ARGUMENT",
            "Argument 'server' must be an https URL.",
            null
        )
        return
    }

    if (token.isNullOrBlank()) {
        result.error(
            "INVALID_ARGUMENT",
            "Argument 'token' must not be null or empty.",
            null
        )
        return
    }

    if (idNumber.isNullOrBlank()) {
        result.error(
            "INVALID_ARGUMENT",
            "Argument 'id' must not be null or empty.",
            null
        )
        return
    }

    val birthDate = call.argument<String>("birthDate")
    val expireDate = call.argument<String>("expireDate")
    val documentNo = call.argument<String>("documentNo")

    val geoLocation = call.argument<Boolean>("geoLocation") ?: false

    // Hem mevcut "lang" key'ini hem de eski/alternatif "language" key'ini destekle.
    val lang = call.argument<String>("lang")
        ?: call.argument<String>("language")
        ?: "tr"

    val email = call.argument<String>("email")
    val phone = call.argument<String>("phone")
    val name = call.argument<String>("name")

    val apiVersionString = call.argument<String>("apiVersion")
    val apiVersion = when (apiVersionString) {
        "v1" -> AmaniVersion.V1
        "v2", null -> AmaniVersion.V2
        else -> AmaniVersion.V2
    }

    try {
        AmaniSDKUI.init(
            applicationContext = context,
            serverURL = server,
            amaniVersion = apiVersion
        )

        AmaniSDKUI.goToKycActivity(
            activity = componentActivity,
            resultLauncher = launcher,
            idNumber = idNumber,
            authToken = token,
            language = lang,
            geoLocation = geoLocation,
            birthDate = birthDate,
            expireDate = expireDate,
            documentNumber = documentNo,
            userEmail = email,
            userPhoneNumber = phone,
            userFullName = name
        )
        result.success(null)
    } catch (e: Exception) {
        Log.e(TAG, "Failed to start KYC activity with token", e)
        result.error("START_KYC_FAILED", "Failed to start KYC activity", null)
    }
}

    companion object {
        private const val TAG = "AmaniFlutterBridge"
    }
}
