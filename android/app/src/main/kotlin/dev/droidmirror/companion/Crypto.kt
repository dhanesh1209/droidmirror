package dev.droidmirror.companion

import java.io.DataInputStream
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class CompanionCryptoException(message: String) : Exception(message)

/**
 * One encrypted session with the Mac. Mirrors CompanionCrypto.swift; see PLAN.md "Wire protocol (v1)".
 * Frame = 4-byte big-endian length, then nonce(12) || ciphertext || tag(16) (AES-256-GCM, no AAD).
 * Plaintext = seq(8, big-endian) || payload. A fresh channel (fresh salts) is created per connection.
 */
class CompanionChannel(secret: ByteArray, macSalt: ByteArray, phoneSalt: ByteArray, isPhone: Boolean = true) {
    private val sendKey: ByteArray
    private val receiveKey: ByteArray
    private var sendSeq = 0L
    private var lastReceivedSeq = 0L

    init {
        require(secret.size == SECRET_LENGTH) { "secret must be 32 bytes" }
        require(macSalt.size == SALT_LENGTH && phoneSalt.size == SALT_LENGTH) { "salts must be 16 bytes" }
        val salt = macSalt + phoneSalt
        val macToPhone = derive(secret, "mac->phone", salt)
        val phoneToMac = derive(secret, "phone->mac", salt)
        if (isPhone) { sendKey = phoneToMac; receiveKey = macToPhone } else { sendKey = macToPhone; receiveKey = phoneToMac }
    }

    /** Returns the full frame (length prefix + body). `nonce` is only for test vectors. */
    @Synchronized
    fun seal(payload: ByteArray, nonce: ByteArray? = null): ByteArray {
        sendSeq += 1
        val plaintext = ByteBuffer.allocate(8 + payload.size).putLong(sendSeq).put(payload).array()
        val n = nonce ?: ByteArray(NONCE_LENGTH).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sendKey, "AES"), GCMParameterSpec(TAG_LENGTH * 8, n))
        val body = n + cipher.doFinal(plaintext)            // doFinal returns ciphertext || tag
        if (body.size > MAX_BODY) throw CompanionCryptoException("frame too large")
        return ByteBuffer.allocate(4 + body.size).putInt(body.size).put(body).array()
    }

    /** Decrypts one frame body (no length prefix). Rejects tampering, wrong session/direction and replays. */
    @Synchronized
    fun open(body: ByteArray): ByteArray {
        if (body.size < NONCE_LENGTH + 8 + TAG_LENGTH || body.size > MAX_BODY) throw CompanionCryptoException("malformed frame")
        val nonce = body.copyOfRange(0, NONCE_LENGTH)
        val ciphertextAndTag = body.copyOfRange(NONCE_LENGTH, body.size)
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiveKey, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
            cipher.doFinal(ciphertextAndTag)
        } catch (e: GeneralSecurityException) {
            throw CompanionCryptoException("authentication failed")
        }
        val seq = ByteBuffer.wrap(plaintext, 0, 8).long
        if (seq <= lastReceivedSeq) throw CompanionCryptoException("replayed or out of order")
        lastReceivedSeq = seq
        return plaintext.copyOfRange(8, plaintext.size)
    }

    companion object {
        const val SECRET_LENGTH = 32
        const val SALT_LENGTH = 16
        const val NONCE_LENGTH = 12
        const val TAG_LENGTH = 16
        const val MAX_BODY = 1 shl 20

        /** Per-direction, per-session key = HMAC-SHA256(secret, label || salt). */
        fun derive(secret: ByteArray, label: String, salt: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(secret, "HmacSHA256"))
            mac.update(label.toByteArray(Charsets.UTF_8))
            mac.update(salt)
            return mac.doFinal()
        }

        /** Reads one frame body from a blocking stream. */
        fun readBody(input: DataInputStream): ByteArray {
            val length = input.readInt()
            if (length < 0 || length > MAX_BODY) throw CompanionCryptoException("frame too large")
            val body = ByteArray(length)
            input.readFully(body)
            return body
        }
    }
}
