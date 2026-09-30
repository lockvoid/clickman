package com.lockvoid.clickman

import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

/** The oldest waiting events one request carries, and the body that carries them. */
internal object Batch {
    const val MAX_EVENTS = 100
    const val MAX_BYTES = 900_000

    /** How many of [bodies], oldest first, one batch takes (batches.json). */
    fun cut(bodies: List<String>, maxEvents: Int, maxBytes: Int): Int {
        var taken = 0
        var joined = -1
        for (body in bodies.take(maxEvents)) {
            joined += 1 + body.encodeToByteArray().size
            if (taken > 0 && joined > maxBytes) break
            taken += 1
        }
        return taken
    }

    /** `{"sentAt": …, "batch": [bodies]}`, gzipped. */
    fun encode(sentAt: Long, bodies: List<String>): ByteArray {
        val json = """{"sentAt":"${Timestamp.format(sentAt)}","batch":[${bodies.joinToString(",")}]}"""
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(json.encodeToByteArray()) }
        return output.toByteArray()
    }
}
