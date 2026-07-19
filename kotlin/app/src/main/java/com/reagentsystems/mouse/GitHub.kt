package com.reagentsystems.mouse

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Base64

/**
 * GitHub sign-in via the OAuth Device Flow against a classic OAuth App with `repo` scope: the
 * token acts as the user — every repo they can touch, no installation step, no expiry. Mirrors
 * `GitHubAuth.swift` (which also records why the GitHub App provider was removed). Tokens live
 * in app-private storage (Android's sandbox); the login handle is cached for restore.
 */
object GitHub {
    /** Public identifier of the Mouse OAuth App (not a secret). */
    private const val clientID = "Ov23liZpd88m5S0nz1ZS"

    sealed class Phase {
        object SignedOut : Phase()
        object RequestingCode : Phase()
        data class AwaitingAuthorization(val code: String, val url: String) : Phase()
        data class SignedIn(val login: String) : Phase()
        data class Failed(val reason: String) : Phase()
    }

    var phase by mutableStateOf<Phase>(Phase.SignedOut)
        private set

    private lateinit var prefs: android.content.SharedPreferences

    fun attach(context: Context) {
        prefs = context.getSharedPreferences("mouse.github", Context.MODE_PRIVATE)
        val login = prefs.getString("login", null)
        if (login != null && accessToken != null) phase = Phase.SignedIn(login)
    }

    val accessToken: String? get() = if (::prefs.isInitialized) prefs.getString("access-token", null) else null

    private fun store(token: String, login: String) {
        prefs.edit().putString("access-token", token).putString("login", login).apply()
    }

    fun signOut() {
        if (::prefs.isInitialized) prefs.edit().clear().apply()
        phase = Phase.SignedOut
    }

    /** Kick off Device Flow: request a code, then poll until the user authorizes. */
    suspend fun signIn() {
        phase = Phase.RequestingCode
        try {
            val start = withContext(Dispatchers.IO) {
                postForm("https://github.com/login/device/code", mapOf("client_id" to clientID, "scope" to "repo"))
            }
            val deviceCode = start.getString("device_code")
            val userCode = start.getString("user_code")
            val verifyUrl = start.getString("verification_uri")
            var interval = start.optInt("interval", 5)
            phase = Phase.AwaitingAuthorization(userCode, verifyUrl)

            val deadline = System.currentTimeMillis() + 15 * 60_000
            while (System.currentTimeMillis() < deadline) {
                delay(interval * 1000L)
                val poll = withContext(Dispatchers.IO) {
                    postForm("https://github.com/login/oauth/access_token", mapOf(
                        "client_id" to clientID,
                        "device_code" to deviceCode,
                        "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                    ))
                }
                val token = poll.optString("access_token", "")
                if (token.isNotEmpty()) {
                    val login = withContext(Dispatchers.IO) { fetchLogin(token) }
                    store(token, login)
                    phase = Phase.SignedIn(login)
                    return
                }
                when (poll.optString("error")) {
                    "authorization_pending" -> {}
                    "slow_down" -> interval += 5
                    else -> { phase = Phase.Failed(poll.optString("error_description", "sign-in failed")); return }
                }
            }
            phase = Phase.Failed("device code expired")
        } catch (e: Exception) {
            phase = Phase.Failed(e.message ?: "sign-in failed")
        }
    }

    private fun fetchLogin(token: String): String =
        JSONObject(String(getBytes("https://api.github.com/user", token))).getString("login")

    // MARK: - HTTP helpers (zero-dependency: HttpURLConnection + org.json) ----

    fun getBytes(urlString: String, token: String?): ByteArray {
        val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
            setRequestProperty("Accept", "application/vnd.github+json")
            if (token != null) setRequestProperty("Authorization", "Bearer $token")
            instanceFollowRedirects = true
        }
        return connection.readOrThrow()
    }

    fun remoteHeadSha(repoFullName: String, token: String): String {
        val data = getBytes("https://api.github.com/repos/$repoFullName/commits?per_page=1", token)
        val list = JSONArray(String(data))
        if (list.length() == 0) throw Exception("no commits")
        return list.getJSONObject(0).getString("sha")
    }

    private fun postForm(urlString: String, form: Map<String, String>): JSONObject {
        val body = form.entries.joinToString("&") {
            "${URLEncoder.encode(it.key, "UTF-8")}=${URLEncoder.encode(it.value, "UTF-8")}"
        }
        val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        connection.outputStream.use { it.write(body.toByteArray()) }
        return JSONObject(String(connection.readOrThrow()))
    }

    fun apiJson(method: String, urlString: String, token: String, body: JSONObject? = null): JSONObject {
        val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        if (body != null) connection.outputStream.use { it.write(body.toString().toByteArray()) }
        val text = String(connection.readOrThrow())
        return if (text.isEmpty()) JSONObject() else JSONObject(text)
    }

    private fun HttpURLConnection.readOrThrow(): ByteArray {
        val code = responseCode
        val stream = if (code in 200..299) inputStream else errorStream
        val out = ByteArrayOutputStream()
        stream?.use { it.copyTo(out) }
        if (code !in 200..299) {
            val detail = runCatching { JSONObject(String(out.toByteArray())).optString("message") }.getOrNull()
            throw Exception("GitHub said $code${if (detail.isNullOrEmpty()) "" else ": $detail"}")
        }
        return out.toByteArray()
    }
}

/**
 * Commits the workspace's edited files back to GitHub as ONE real commit via the Git Data API —
 * no libgit2, no .git: head commit → base tree → a blob per file → new tree → commit → fast-
 * forward the ref. Mirrors `GitHubPush.swift`.
 */
object GitHubPush {
    suspend fun push(repo: String, root: java.io.File, paths: List<String>, message: String, token: String): String =
        withContext(Dispatchers.IO) {
            val api = "https://api.github.com/repos/$repo"
            val branch = GitHub.apiJson("GET", api, token).getString("default_branch")
            val ref = GitHub.apiJson("GET", "$api/git/ref/heads/$branch", token)
            val headSha = ref.getJSONObject("object").getString("sha")
            val baseTree = GitHub.apiJson("GET", "$api/git/commits/$headSha", token)
                .getJSONObject("tree").getString("sha")

            val entries = JSONArray()
            for (path in paths.sorted()) {
                val file = java.io.File(root, path)
                if (!file.exists()) continue   // edited then deleted
                val blob = GitHub.apiJson("POST", "$api/git/blobs", token, JSONObject()
                    .put("content", Base64.getEncoder().encodeToString(file.readBytes()))
                    .put("encoding", "base64"))
                entries.put(JSONObject()
                    .put("path", path).put("mode", "100644").put("type", "blob")
                    .put("sha", blob.getString("sha")))
            }
            if (entries.length() == 0) throw Exception("nothing to push")

            val tree = GitHub.apiJson("POST", "$api/git/trees", token, JSONObject()
                .put("base_tree", baseTree).put("tree", entries)).getString("sha")
            val commit = GitHub.apiJson("POST", "$api/git/commits", token, JSONObject()
                .put("message", message).put("tree", tree).put("parents", JSONArray().put(headSha)))
                .getString("sha")
            GitHub.apiJson("PATCH", "$api/git/refs/heads/$branch", token, JSONObject().put("sha", commit))
            commit
        }
}
