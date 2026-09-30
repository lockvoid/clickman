package com.lockvoid.clickman

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class QueueTest {
    private val directory: File = Files.createTempDirectory("clickman-queue").toFile()
    private val file = File(directory, "queue.sqlite")

    @AfterTest
    fun tearDown() {
        directory.deleteRecursively()
    }

    private fun tables(file: File): List<String> =
        inspect(file) { db -> db.query("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name") { it.getText(0) } }

    @Test
    fun openingCreatesTheDirectoriesAndAFormatOneStore() {
        val nested = File(directory, "no/such/dir/queue.sqlite")

        openQueue(nested).use { queue ->
            val identity = queue.transaction { it.identity() }
            assertEquals("*", identity.externalId)
            assertEquals(buildJsonObject { }, identity.traits)
            assertNull(identity.release)
        }

        assertEquals(1L, inspect(nested) { it.long("PRAGMA user_version") })
        assertEquals("wal", inspect(nested) { db -> db.single("PRAGMA journal_mode") { it.getText(0) } })
        assertEquals(listOf("events", "identity", "sqlite_sequence"), tables(nested))
    }

    @Test
    fun aStoreOfTheOldCoreIsAdopted() {
        val state = mapOf("external_id" to "42", "traits" to """{"plan":"pro"}""", "app_version" to "1.40", "app_build" to "140", "context" to "{}")
        createOldCoreStore(file, state, body = """{"event":"left_behind"}""")

        openQueue(file).use { queue ->
            val identity = queue.transaction { it.identity() }
            assertEquals("42", identity.externalId)
            assertEquals(buildJsonObject { put("plan", "pro") }, identity.traits)
            assertEquals(Release("1.40", "140"), identity.release)
            assertEquals(listOf("""{"event":"left_behind"}"""), queue.transaction { tx -> tx.oldest(10).map { it.body } })
        }

        assertEquals(listOf("events", "identity", "sqlite_sequence"), tables(file))
        assertEquals(1L, inspect(file) { it.long("PRAGMA user_version") })
    }

    @Test
    fun anOldCoreStoreThatNeverIdentifiedIsAdoptedAnonymous() {
        createOldCoreStore(file, emptyMap(), body = "{}")

        val identity = openQueue(file).use { queue -> queue.transaction { it.identity() } }

        assertEquals("*", identity.externalId)
        assertEquals(buildJsonObject { }, identity.traits)
        assertNull(identity.release)
    }

    @Test
    fun aStoreOfANewerClickManIsRefusedAndLeftAsItWas() {
        inspect(file) { it.exec("PRAGMA user_version = 2") }

        val error = assertFailsWith<ClickManException> { openQueue(file) }

        assertTrue(error.message.orEmpty().endsWith("written by a newer ClickMan"), error.message)
        assertEquals(2L, inspect(file) { it.long("PRAGMA user_version") })
        assertEquals(emptyList(), tables(file))
    }

    @Test
    fun reopeningKeepsTheEventsAndTheIdentity() {
        openQueue(file).use { queue ->
            queue.transaction {
                it.insert(TestClock.START, "{}", maxQueue = 10)
                it.setExternalId("42")
            }
        }

        openQueue(file).use { queue ->
            assertEquals(1, queue.transaction { it.count() })
            assertEquals("42", queue.transaction { it.identity() }.externalId)
        }
    }

    @Test
    fun aFailedTransactionLeavesNothingBehind() {
        openQueue(file).use { queue ->
            assertFailsWith<IllegalStateException> {
                queue.transaction {
                    it.insert(TestClock.START, "{}", maxQueue = 10)
                    error("the work failed")
                }
            }

            assertEquals(0, queue.transaction { it.count() })
        }
    }

    @Test
    fun aClosedQueueRefusesTransactionsAndClosesOnce() {
        val queue = openQueue(file)
        queue.close()
        queue.close()

        val error = assertFailsWith<ClickManException> { queue.transaction { it.count() } }
        assertEquals("ClickMan is closed", error.message)
    }
}
