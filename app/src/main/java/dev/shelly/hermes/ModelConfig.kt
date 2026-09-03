package dev.shelly.hermes

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

data class ModelConfig(
    val endpoint: String,
    val model: String,
    val apiKey: String,
    val contextWindow: Int = DEFAULT_CONTEXT_WINDOW,
) {
    companion object {
        const val DEFAULT_CONTEXT_WINDOW = 128_000
    }
}
interface ModelConfigStore { fun save(config: ModelConfig); fun load(): ModelConfig? }
class AndroidKeyStoreModelConfig(private val context: Context) : ModelConfigStore {
    private val alias = "shelly_model_config"
    private fun key() = (KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(alias, null) ?: run {
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()) }.generateKey()
    })
    override fun save(config: ModelConfig) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val p = "${config.endpoint}\n${config.model}\n${config.apiKey}\n${config.contextWindow}".toByteArray(StandardCharsets.UTF_8)
        context.getSharedPreferences("secret_config", 0).edit()
            .putString("iv", android.util.Base64.encodeToString(c.iv, 2))
            .putString("blob", android.util.Base64.encodeToString(c.doFinal(p), 2))
            .apply()
    }
    override fun load(): ModelConfig? = runCatching {
        val p = context.getSharedPreferences("secret_config", 0)
        val iv = android.util.Base64.decode(p.getString("iv", null), 2)
        val blob = android.util.Base64.decode(p.getString("blob", null), 2)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        val parts = c.doFinal(blob).toString(StandardCharsets.UTF_8).split("\n")
        ModelConfig(
            endpoint = parts[0],
            model = parts[1],
            apiKey = parts[2],
            contextWindow = parts.getOrNull(3)?.toIntOrNull() ?: ModelConfig.DEFAULT_CONTEXT_WINDOW,
        )
    }.getOrNull()
}
