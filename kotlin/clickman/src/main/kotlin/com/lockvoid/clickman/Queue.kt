package com.lockvoid.clickman

import com.sun.jna.Pointer
import java.io.Closeable
import java.io.File
import java.util.concurrent.locks.ReentrantReadWriteLock
import java.util.logging.Logger
import kotlin.concurrent.read
import kotlin.concurrent.write

internal class Batch(val id: Long, val events: Int, val body: ByteArray)

/**
 * The device queue of the Rust core. The core serializes calls itself, so any
 * thread may call; the lock only keeps a call from reaching the core once
 * [close] has freed it.
 */
internal class Queue(storage: File, configurationJson: String, private val logger: Logger) : Closeable {
    private val native = ClickManNative.INSTANCE
    private val handle: Pointer
    private val lock = ReentrantReadWriteLock()
    private var closed = false

    init {
        storage.absoluteFile.parentFile.mkdirs()
        handle = native.clickman_open(storage.path, configurationJson)
            ?: throw ClickManException("ClickMan could not open ${storage.path}: ${native.clickman_last_error()}")
    }

    fun identify(externalId: String) = call("identify") { native.clickman_identify(handle, externalId) }

    fun reset() = call("reset") { native.clickman_reset(handle) }

    fun setContext(json: String) = call("set the context") { native.clickman_set_context(handle, json) }

    fun setTraits(json: String) = call("set the traits") { native.clickman_set_traits(handle, json) }

    fun appLaunched(version: String, build: String, nowMs: Long) =
        call("record the launch") { native.clickman_app_launched(handle, version, build, nowMs) }

    fun track(event: String, propertiesJson: String, timestampMs: Long) =
        call("track $event") { native.clickman_track(handle, event, propertiesJson, timestampMs) }

    fun takeBatch(nowMs: Long, force: Boolean): Batch? =
        lock.read {
            if (closed) {
                return null
            }

            val out = ClickManBatch()
            val taken = native.clickman_take_batch(handle, nowMs, force, out)
            if (taken != 1) {
                report(taken, "take a batch")
                return null
            }

            val pointer = checkNotNull(out.body.ptr) { "a taken batch has a body" }
            val body = pointer.getByteArray(0, out.body.len.toInt())
            native.clickman_buf_free(ClickManBuf.ByValue().also {
                it.ptr = out.body.ptr
                it.len = out.body.len
            })
            Batch(out.id, out.events, body)
        }

    fun complete(batch: Batch, status: Int, retryAfterMs: Long, nowMs: Long) =
        call("complete batch ${batch.id}") { native.clickman_complete_batch(handle, batch.id, status, retryAfterMs, nowMs) }

    val pending: Int
        get() = lock.read { if (closed) 0 else native.clickman_pending(handle).toInt() }

    override fun close() {
        lock.write {
            if (!closed) {
                closed = true
                native.clickman_close(handle)
            }
        }
    }

    private fun call(action: String, work: () -> Int) {
        lock.read {
            if (closed) {
                logger.warning("ClickMan could not $action: it is closed")
                return
            }
            report(work(), action)
        }
    }

    private fun report(result: Int, action: String) {
        if (result < 0) {
            logger.warning("ClickMan could not $action: ${native.clickman_last_error()}")
        }
    }
}
