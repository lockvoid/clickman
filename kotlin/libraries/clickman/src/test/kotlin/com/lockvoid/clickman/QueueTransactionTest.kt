package com.lockvoid.clickman

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class QueueTransactionTest {
    private val directory: File = Files.createTempDirectory("clickman-transaction").toFile()
    private val queue = openQueue(File(directory, "queue.sqlite"))

    @AfterTest
    fun tearDown() {
        queue.close()
        directory.deleteRecursively()
    }

    private fun insert(vararg bodies: String, createdAt: Long = TestClock.START, maxQueue: Int = 10_000) {
        queue.transaction { tx -> bodies.forEach { tx.insert(createdAt, it, maxQueue) } }
    }

    private fun waiting(): List<Pair<Long, String>> = queue.transaction { tx -> tx.oldest(Int.MAX_VALUE).map { it.seq to it.body } }

    @Test
    fun anInsertDropsTheOldestBeyondMaxQueue() {
        insert("1", "2", "3", "4", "5", maxQueue = 3)

        assertEquals(listOf(3L to "3", 4L to "4", 5L to "5"), waiting())
    }

    @Test
    fun aPurgeDeletesOnlyEventsTrackedBeforeTheCutoff() {
        insert("old", createdAt = 1_000)
        insert("edge", createdAt = 2_000)
        insert("new", createdAt = 3_000)

        queue.transaction { it.purge(trackedBefore = 2_000) }

        assertEquals(listOf("edge", "new"), waiting().map { it.second })
    }

    @Test
    fun theBacklogCountsTheWaitingEventsAndFindsTheOldest() {
        assertNull(queue.transaction { it.backlog() })

        insert("a", createdAt = 5_000)
        insert("b", createdAt = 4_000)
        val backlog = queue.transaction { it.backlog() }

        assertEquals(2L, backlog?.count)
        assertEquals(4_000L, backlog?.oldest)
    }

    @Test
    fun theOldestComeFirstUpToTheLimit() {
        insert("a", "b", "c")

        assertEquals(listOf("a", "b"), queue.transaction { tx -> tx.oldest(2).map { it.body } })
    }

    @Test
    fun deletingThroughASeqDeletesTheBatchAndKeepsTheRest() {
        insert("a", "b", "c")

        queue.transaction { it.deleteThrough(seq = 2) }

        assertEquals(listOf(3L to "c"), waiting())
        assertEquals(1, queue.transaction { it.count() })
    }

    @Test
    fun theIdentityChangesAndAResetKeepsTheLastLaunch() {
        queue.transaction {
            it.setExternalId("42")
            it.setTraits(buildJsonObject { put("plan", "pro") })
            it.setRelease(Release("1.40", "140"))
        }
        val identified = queue.transaction { it.identity() }

        queue.transaction { it.reset() }
        val anonymous = queue.transaction { it.identity() }

        assertEquals("42", identified.externalId)
        assertEquals(buildJsonObject { put("plan", "pro") }, identified.traits)
        assertEquals("*", anonymous.externalId)
        assertEquals(buildJsonObject { }, anonymous.traits)
        assertEquals(Release("1.40", "140"), anonymous.release)
    }
}
