package com.lockvoid.clickman

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.logging.Logger

/**
 * Sends the batches the queue hands out, one at a time, and reports each
 * outcome back so the core can retry with backoff (docs/PROTOCOL.md).
 */
internal class Sender(
    private val queue: Queue,
    endpoint: String,
    private val writeKey: String,
    private val logger: Logger,
) {
    private val url = URI.create("${endpoint.trimEnd('/')}/v1/batch").toURL()

    fun drain(force: Boolean) {
        while (true) {
            val batch = queue.takeBatch(System.currentTimeMillis(), force) ?: return
            val (status, retryAfterMs) = send(batch)
            queue.complete(batch, status, retryAfterMs, System.currentTimeMillis())

            if (status !in 200..299) {
                logger.info("ClickMan batch ${batch.id} ended with status $status; the core retries it")
                return
            }
        }
    }

    private fun send(batch: Batch): Pair<Int, Long> {
        val connection = url.openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.setRequestProperty("Authorization", "Bearer $writeKey")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Content-Encoding", "gzip")
            connection.setFixedLengthStreamingMode(batch.body.size)
            connection.outputStream.use { it.write(batch.body) }

            val status = connection.responseCode
            val retryAfterMs = connection.getHeaderField("Retry-After")?.toLongOrNull()?.times(1000) ?: -1
            (if (status >= 400) connection.errorStream else connection.inputStream)?.use { it.readBytes() }
            status to retryAfterMs
        } catch (error: IOException) {
            logger.info("ClickMan could not reach $url: ${error.message}")
            0 to -1L
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val TIMEOUT_MS = 30_000
    }
}
