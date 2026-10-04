package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.hardware.fingerprint.FingerprintManager
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** A per-use biometric Keystore key wraps a random data key. Only ciphertext
 * is persisted; the unwrapped key stays in memory for refresh-token rotation. */
class BiometricLogin(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val preferences = activity.getSharedPreferences("mdesk_biometric", Context.MODE_PRIVATE)
    private val alias = "mdesk.biometric.login.v1"
    private var dataKey: ByteArray? = null
    private var cancellation: CancellationSignal? = null
    private var pending: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "has_session" -> result.success(preferences.contains("payload"))
                "is_available" -> result.success(isAvailable())
                "clear" -> { cancel(); clear(); result.success(null) }
                "cancel" -> { cancel(); result.success(null) }
                "enroll", "unlock" -> {
                    if (pending != null) { result.error("busy", null, null); return }
                    if (!isAvailable()) { result.error("unavailable", null, null); return }
                    if (Build.VERSION.SDK_INT >= 28) authenticate(call, result)
                }
                "update" -> {
                    val key = dataKey ?: throw IllegalStateException("Vault is locked")
                    savePayload(call.arguments as String, key)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (pending === result) {
                pending = null
                cancellation?.cancel()
                cancellation = null
            }
            result.error(if (error is KeyPermanentlyInvalidatedException) "invalidated" else "storage", null, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun isAvailable(): Boolean {
        if (Build.VERSION.SDK_INT >= 30) {
            return activity.getSystemService(BiometricManager::class.java)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
        }
        if (Build.VERSION.SDK_INT == 29) {
            return activity.getSystemService(BiometricManager::class.java).canAuthenticate() == BiometricManager.BIOMETRIC_SUCCESS
        }
        if (Build.VERSION.SDK_INT == 28) {
            val manager = activity.getSystemService(FingerprintManager::class.java)
            return manager != null && manager.isHardwareDetected && manager.hasEnrolledFingerprints()
        }
        return false
    }

    @androidx.annotation.RequiresApi(28)
    private fun authenticate(call: MethodCall, result: MethodChannel.Result) {
        val enrolling = call.method == "enroll"
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        var newKey: ByteArray? = null
        if (enrolling) {
            clear()
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(true)
                .setInvalidatedByBiometricEnrollment(true)
            if (Build.VERSION.SDK_INT >= 30) builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            generator.init(builder.build())
            cipher.init(Cipher.ENCRYPT_MODE, generator.generateKey())
            newKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
        } else {
            if (!preferences.contains("payload") || !keyStore.containsAlias(alias)) {
                result.error("invalidated", null, null); return
            }
            val wrapped = JSONObject(preferences.getString("wrapped_key", "")!!)
            cipher.init(Cipher.DECRYPT_MODE, keyStore.getKey(alias, null) as SecretKey,
                GCMParameterSpec(128, decode(wrapped.getString("iv"))))
        }
        val enrollKey = newKey
        pending = result
        cancellation = CancellationSignal()
        val builder = BiometricPrompt.Builder(activity)
            .setTitle("MDesk 생체인증 로그인")
            .setSubtitle(if (enrolling) "로그인 정보를 보호하기 위해 인증해 주세요" else "저장된 계정으로 로그인합니다")
            .setNegativeButton("취소", activity.mainExecutor) { _, _ -> cancel() }
        if (Build.VERSION.SDK_INT >= 30) builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        builder.build().authenticate(BiometricPrompt.CryptoObject(cipher), cancellation!!, activity.mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    if (pending !== result) return
                    pending = null
                    cancellation = null
                    if (code == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                        code == BiometricPrompt.BIOMETRIC_ERROR_CANCELED) result.success(null)
                    else result.error("unavailable", null, null)
                }

                override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                    if (pending !== result) return
                    pending = null
                    cancellation = null
                    try {
                        val authenticated = authentication.cryptoObject?.cipher ?: throw IllegalStateException()
                        if (enrolling) {
                            val wrapped = authenticated.doFinal(enrollKey!!)
                            check(preferences.edit().putString("wrapped_key", JSONObject()
                                .put("iv", encode(authenticated.iv)).put("data", encode(wrapped)).toString()).commit())
                            dataKey = enrollKey
                            savePayload(call.arguments as String, enrollKey)
                            result.success(true)
                        } else {
                            val wrapped = JSONObject(preferences.getString("wrapped_key", "")!!)
                            dataKey = authenticated.doFinal(decode(wrapped.getString("data")))
                            result.success(readPayload(dataKey!!))
                        }
                    } catch (error: Exception) {
                        clear()
                        result.error("invalidated", null, null)
                    }
                }
            })
    }

    private fun savePayload(payload: String, key: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        val encrypted = cipher.doFinal(payload.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString("payload", JSONObject()
            .put("iv", encode(cipher.iv)).put("data", encode(encrypted)).toString()).commit())
    }

    private fun readPayload(key: ByteArray): String {
        val payload = JSONObject(preferences.getString("payload", "")!!)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, decode(payload.getString("iv"))))
        return String(cipher.doFinal(decode(payload.getString("data"))), Charsets.UTF_8)
    }

    fun cancel() {
        val result = pending
        pending = null
        cancellation?.cancel()
        cancellation = null
        result?.success(null)
    }

    fun dispose() { cancel(); dataKey?.fill(0); dataKey = null }

    private fun clear() {
        dataKey?.fill(0)
        dataKey = null
        try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
        } finally {
            check(preferences.edit().clear().commit())
        }
    }

    private fun encode(value: ByteArray) = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
}
