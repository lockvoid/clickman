package com.lockvoid.clickman

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.Structure

/** `clickman_buf`: an owned byte buffer, released once with `clickman_buf_free`. */
@Structure.FieldOrder("ptr", "len")
internal open class ClickManBuf : Structure() {
    @JvmField var ptr: Pointer? = null
    @JvmField var len: NativeLong = NativeLong(0)

    internal class ByValue : ClickManBuf(), Structure.ByValue
}

/** `clickman_batch`: the id to complete, the number of events and the gzipped body. */
@Structure.FieldOrder("id", "events", "body")
internal class ClickManBatch : Structure() {
    @JvmField var id: Long = 0
    @JvmField var events: Int = 0
    @JvmField var body: ClickManBuf = ClickManBuf()
}

/**
 * The extern-C boundary of the ClickMan core, one to one with
 * `crates/clickman-core/include/clickman.h`. Methods carry the C symbol names
 * because JNA binds by name.
 */
@Suppress("FunctionName")
internal interface ClickManNative : Library {
    fun clickman_version(): String

    fun clickman_last_error(): String

    fun clickman_open(path: String, configJson: String?): Pointer?

    fun clickman_close(client: Pointer)

    fun clickman_identify(client: Pointer, externalId: String): Int

    fun clickman_reset(client: Pointer): Int

    fun clickman_set_context(client: Pointer, contextJson: String): Int

    fun clickman_set_traits(client: Pointer, traitsJson: String): Int

    fun clickman_app_launched(client: Pointer, version: String, build: String, nowMs: Long): Int

    fun clickman_track(client: Pointer, event: String, propertiesJson: String?, timestampMs: Long): Int

    fun clickman_take_batch(client: Pointer, nowMs: Long, force: Boolean, out: ClickManBatch): Int

    fun clickman_complete_batch(client: Pointer, batchId: Long, httpStatus: Int, retryAfterMs: Long, nowMs: Long): Int

    fun clickman_pending(client: Pointer): Long

    fun clickman_buf_free(buf: ClickManBuf.ByValue)

    companion object {
        val INSTANCE: ClickManNative by lazy {
            Native.load("clickman_core", ClickManNative::class.java, mapOf(Library.OPTION_STRING_ENCODING to "UTF-8"))
        }
    }
}
