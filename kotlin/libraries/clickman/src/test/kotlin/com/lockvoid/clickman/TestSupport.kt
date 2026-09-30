package com.lockvoid.clickman

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList
import java.util.logging.Handler
import java.util.logging.LogRecord
import kotlin.random.Random
import kotlin.time.Duration
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** A clock the test moves by hand. */
internal class TestClock(@Volatile var millis: Long = START) {
    fun advance(duration: Duration) {
        millis += duration.inWholeMilliseconds
    }

    companion object {
        val START: Long = Instant.parse("2026-09-30T12:00:00.123Z").toEpochMilli()
    }
}

/** A random source at the low or the high end of every draw, for the edges of a jitter. */
internal class EdgeRandom(private val high: Boolean) : Random() {
    override fun nextBits(bitCount: Int): Int = if (high) -1 ushr (32 - bitCount) else 0
}

/** What the ClickMan logger publishes while [block] runs. */
internal fun logged(block: () -> Unit): List<LogRecord> {
    val records = CopyOnWriteArrayList<LogRecord>()
    val handler = object : Handler() {
        override fun publish(record: LogRecord) {
            records += record
        }

        override fun flush() = Unit

        override fun close() = Unit
    }
    logger.addHandler(handler)
    try {
        block()
    } finally {
        logger.removeHandler(handler)
    }
    return records
}

internal fun eventually(what: String, condition: () -> Boolean) {
    val deadline = System.nanoTime() + 10_000_000_000
    while (!condition()) {
        check(System.nanoTime() < deadline) { "timed out waiting for $what" }
        Thread.sleep(20)
    }
}

internal fun openQueue(file: File): Queue = Queue.open(file, BundledSQLiteDriver())

/** The waiting bodies, oldest first. */
internal fun Queue.bodies(): List<JsonObject> =
    transaction { it.oldest(Int.MAX_VALUE) }.map { Json.parseToJsonElement(it.body).jsonObject }

/** A raw connection to a store file, for what the client itself never reads. */
internal fun <T> inspect(file: File, read: (SQLiteConnection) -> T): T = BundledSQLiteDriver().open(file.path).use(read)

/** A store as the 0.1 Rust core left it: format 0, a `state` table, a leased event. */
internal fun createOldCoreStore(file: File, state: Map<String, String>, body: String) {
    inspect(file) { db ->
        db.exec("CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL, body TEXT NOT NULL, batch_id INTEGER)")
        db.exec("CREATE INDEX events_batch ON events (batch_id)")
        db.exec("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        for ((key, value) in state) db.exec("INSERT INTO state (key, value) VALUES (?, ?)", listOf(key, value))
        db.exec("INSERT INTO events (created_at, body, batch_id) VALUES (?, ?, 7)", listOf(TestClock.START, body))
    }
}

internal fun JsonObject.text(key: String): String? = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.child(key: String): JsonObject? = get(key) as? JsonObject

internal fun JsonObject.children(key: String): List<JsonObject> = getValue(key).jsonArray.map { it.jsonObject }
