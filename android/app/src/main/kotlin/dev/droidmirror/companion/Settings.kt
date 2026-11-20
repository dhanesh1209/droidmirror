package dev.droidmirror.companion

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PairingConfig(val host: String, val port: Int, val secret: ByteArray, val macName: String)

/** Stores the pairing config. The secret is encrypted with a key that never leaves the Android Keystore. */
class Settings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("droidmirror", Context.MODE_PRIVATE)

    fun load(): PairingConfig? {
        val host = prefs.getString("host", null) ?: return null
        val port = prefs.getInt("port", 0)
        val wrapped = prefs.getString("secret", null) ?: return null
        val secret = SecretBox.unwrap(wrapped) ?: return null
        return PairingConfig(host, port, secret, prefs.getString("name", "Mac") ?: "Mac")
    }

    fun save(c: PairingConfig) {
        prefs.edit()
            .putString("host", c.host).putInt("port", c.port)
            .putString("secret", SecretBox.wrap(c.secret)).putString("name", c.macName)
            .apply()
    }

    fun clear() = prefs.edit().clear().apply()

    companion object {
        private val HOST = Regex("^[A-Za-z0-9][A-Za-z0-9.-]*$")

        /** Parses the QR payload: {"v":1,"host":...,"port":...,"secret":"<base64>","name":...}. */
        fun parsePayload(json: String): PairingConfig {
            val o = JSONObject(json)
            require(o.optInt("v") == 1) { "unsupported pairing version" }
            val host = o.getString("host")
            require(HOST.matches(host)) { "bad host" }
            val port = o.getInt("port")
            require(port in 1..65535) { "bad port" }
            val secret = Base64.decode(o.getString("secret"), Base64.DEFAULT)
            require(secret.size == CompanionChannel.SECRET_LENGTH) { "bad secret" }
            return PairingConfig(host, port, secret, o.optString("name", "Mac").ifEmpty { "Mac" })
        }
    }
}

private object SecretBox {
    private const val ALIAS = "droidmirror_secret_wrap"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun wrap(plain: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(plain), Base64.NO_WRAP)
    }

    fun unwrap(stored: String): ByteArray? = try {
        val raw = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
        cipher.doFinal(raw.copyOfRange(12, raw.size))
    } catch (e: Exception) {
        null
    }
}
