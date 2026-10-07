package id.finbro.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.KeyGenerator
import android.security.keystore.KeyProperties

/** Device-bound HMAC for the app-lock verifier. The key never leaves Android Keystore. */
object PinVerifierChannel {
    private const val NAME = "id.finbro.app/pin_verifier"
    private const val PROVIDER = "AndroidKeyStore"
    private const val ALIAS = "finbro.app_lock.pin_binding.v1"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                val data = call.argument<String>("data")
                if (data.isNullOrEmpty()) {
                    result.error("invalid_arguments", "Verifier data is missing", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "bind" -> result.success(binding(data, create = true))
                    "verify" -> {
                        val expected = call.argument<String>("binding")
                        if (expected.isNullOrEmpty()) {
                            result.error("invalid_arguments", "Verifier binding is missing", null)
                        } else {
                            result.success(verify(data, expected))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // Keystore failures are explicit; Dart must never downgrade to a
                // database-only verifier when this channel is present.
                result.error("keystore_unavailable", "PIN device key unavailable", null)
            }
        }
    }

    private fun binding(data: String, create: Boolean): String {
        val key = key(create) ?: throw IllegalStateException("missing device key")
        return Base64.encodeToString(mac(key, data), Base64.NO_WRAP)
    }

    private fun verify(data: String, expected: String): Boolean {
        val key = key(create = false) ?: throw IllegalStateException("missing device key")
        val actual = mac(key, data)
        val supplied = try { Base64.decode(expected, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { return false }
        if (actual.size != supplied.size) return false
        var difference = 0
        for (i in actual.indices) difference = difference or (actual[i].toInt() xor supplied[i].toInt())
        return difference == 0
    }

    private fun mac(key: SecretKey, data: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(key)
        return mac.doFinal(data.toByteArray(StandardCharsets.UTF_8))
    }

    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        val existing = (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
        if (existing != null || !create) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        return generator.generateKey()
    }
}
