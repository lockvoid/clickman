package com.lockvoid.clickman

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** The ingest server's answer to a batch: status 0 when none came, and what it said, for the log. */
internal class Response(val status: Int, val retryAfter: Duration?, val detail: String)

/** POSTs gzipped batches to `{endpoint}/v1/batch` (docs/PROTOCOL.md, Endpoint). */
internal class Sender(endpoint: String, private val writeKey: String) {
    private val url = URI.create("${endpoint.trimEnd('/')}/v1/batch").toURL()

    init {
        require(url.protocol == "http" || url.protocol == "https") { "the endpoint $endpoint is not an HTTP URL" }
    }

    fun post(body: ByteArray): Response =
        try {
            exchange(url.openConnection() as HttpURLConnection, body)
        } catch (error: IOException) {
            Response(0, null, "no answer from $url: $error")
        }

    private fun exchange(connection: HttpURLConnection, body: ByteArray): Response =
        try {
            write(connection, body)
            read(connection)
        } finally {
            connection.disconnect()
        }

    private fun write(connection: HttpURLConnection, body: ByteArray) {
        connection.requestMethod = "POST"
        connection.instanceFollowRedirects = false
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        connection.setRequestProperty("Authorization", "Bearer $writeKey")
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("Content-Encoding", "gzip")
        connection.doOutput = true
        connection.outputStream.use { it.write(body) }
    }

    private fun read(connection: HttpURLConnection): Response {
        val status = connection.responseCode
        val answer = (if (status >= 400) connection.errorStream else connection.inputStream)?.use { it.prefix(DETAIL_BYTES) }
        return Response(status, retryAfter(connection.getHeaderField("Retry-After")), "HTTP $status ${answer.orEmpty()}")
    }

    /** `Retry-After` in seconds, the form the ingest server sends; any other form is ignored with a warning. */
    private fun retryAfter(header: String?): Duration? {
        if (header == null) return null
        val seconds = header.trim().toLongOrNull()
        if (seconds == null || seconds < 0) {
            logger.warning("ClickMan ignores the Retry-After \"$header\" of $url: it is not a number of seconds")
            return null
        }
        return seconds.seconds
    }

    private fun InputStream.prefix(limit: Int): String {
        val buffer = ByteArray(limit)
        var size = 0
        while (size < limit) {
            val count = read(buffer, size, limit - size)
            if (count < 0) break
            size += count
        }
        return buffer.decodeToString(0, size)
    }

    private companion object {
        const val TIMEOUT_MS = 30_000
        const val DETAIL_BYTES = 512
    }
}
