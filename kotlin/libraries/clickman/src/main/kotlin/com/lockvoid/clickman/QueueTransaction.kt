package com.lockvoid.clickman

import androidx.sqlite.SQLiteConnection
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** An event waiting in the queue: its place in line and its body exactly as it is sent. */
internal class QueuedEvent(val seq: Long, val body: String)

/** How many events are waiting and when the oldest of them was tracked. */
internal class Backlog(val count: Long, val oldest: Long)

/** Who later events are about, their traits and the last launch the store remembers. */
internal class Identity(val externalId: String, val traits: JsonObject, val release: Release?)

/** The queue's reads and writes inside one transaction. */
internal class QueueTransaction(private val db: SQLiteConnection) {
    fun identity(): Identity =
        db.single("SELECT external_id, traits, app_version, app_build FROM identity WHERE id = 1") {
            Identity(it.getText(0), Json.parseToJsonElement(it.getText(1)).jsonObject, release(it.textOrNull(2), it.textOrNull(3)))
        }

    fun setExternalId(externalId: String) {
        db.exec("UPDATE identity SET external_id = ? WHERE id = 1", listOf(externalId))
    }

    fun setTraits(traits: JsonObject) {
        db.exec("UPDATE identity SET traits = ? WHERE id = 1", listOf(traits.toString()))
    }

    fun setRelease(release: Release) {
        db.exec("UPDATE identity SET app_version = ?, app_build = ? WHERE id = 1", listOf(release.version, release.build))
    }

    fun reset() {
        db.exec("UPDATE identity SET external_id = '*', traits = '{}' WHERE id = 1")
    }

    /** Queues [body] and drops the oldest events beyond [maxQueue]. */
    fun insert(createdAt: Long, body: String, maxQueue: Int) {
        db.exec("INSERT INTO events (created_at, body) VALUES (?, ?)", listOf(createdAt, body))
        db.exec(
            "DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq DESC LIMIT -1 OFFSET ?)",
            listOf(maxQueue),
        )
    }

    fun purge(trackedBefore: Long) {
        db.exec("DELETE FROM events WHERE created_at < ?", listOf(trackedBefore))
    }

    /** The waiting events, or null when none is. */
    fun backlog(): Backlog? =
        db.single("SELECT count(*), min(created_at) FROM events") {
            if (it.isNull(1)) null else Backlog(it.getLong(0), it.getLong(1))
        }

    fun oldest(limit: Int): List<QueuedEvent> =
        db.query("SELECT seq, body FROM events ORDER BY seq LIMIT ?", listOf(limit)) { QueuedEvent(it.getLong(0), it.getText(1)) }

    fun deleteThrough(seq: Long) {
        db.exec("DELETE FROM events WHERE seq <= ?", listOf(seq))
    }

    fun count(): Int = db.single("SELECT count(*) FROM events") { it.getInt(0) }

    private fun release(version: String?, build: String?): Release? =
        if (version == null || build == null) null else Release(version, build)
}
