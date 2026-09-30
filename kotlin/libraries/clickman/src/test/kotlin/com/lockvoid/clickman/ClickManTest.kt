package com.lockvoid.clickman

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.logging.Level
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Rule
import org.junit.rules.Timeout

class ClickManTest {
    @get:Rule
    val timeout: Timeout = Timeout.seconds(60)

    private val server = StubServer.start()
    private val directory: File = Files.createTempDirectory("clickman-kotlin").toFile()
    private val storage = File(directory, "queue.sqlite")
    private val clock = TestClock()
    private val opened = mutableListOf<ClickMan>()

    @AfterTest
    fun tearDown() {
        opened.forEach { it.close() }
        server.stop()
        directory.deleteRecursively()
    }

    private fun clickMan(pollInterval: Duration = 1.hours, configure: ClickMan.Configuration.() -> Unit = {}): ClickMan {
        val configuration = ClickMan.Configuration(server.endpoint, "android-key", storage, BundledSQLiteDriver()).apply(configure)
        return ClickMan(configuration, { clock.millis }, Random(3), pollInterval).also { opened += it }
    }

    private fun sent(): List<String?> = server.events.map { it.text("event") }

    @Test
    fun trackedEventsAreSentAsOneGzippedBatchWithTheWriteKey() {
        val clickMan = clickMan()

        clickMan.track("export_completed")
        clickMan.track("paywall_viewed")
        clickMan.flush()

        val request = server.requests.single()
        assertEquals("/v1/batch", request.path)
        assertEquals("Bearer android-key", request.headers["authorization"])
        assertEquals("application/json", request.headers["content-type"])
        assertEquals("gzip", request.headers["content-encoding"])
        assertEquals(listOf("sentAt", "batch"), request.batch.keys.toList())
        assertEquals("2026-09-30T12:00:00.123Z", request.batch.text("sentAt"))
        assertEquals(listOf("export_completed", "paywall_viewed"), sent())
        assertEquals(0, clickMan.pendingEvents)
    }

    @Test
    fun aSentEventIsATrackOfTheActorWithItsMessageIdTimeAndProperties() {
        val clickMan = clickMan()

        clickMan.track("export_completed", mapOf("format" to "mp4", "duration" to 32.5))
        clickMan.flush()

        val event = server.events.single()
        assertEquals("track", event.text("type"))
        assertEquals(7, UUID.fromString(event.text("messageId")).version())
        assertEquals("*", event.text("externalId"))
        assertEquals("2026-09-30T12:00:00.123Z", event.text("timestamp"))
        assertEquals(buildJsonObject { put("format", "mp4"); put("duration", 32.5) }, event.child("properties"))
    }

    @Test
    fun everyEventCarriesTheHostContextAndTheLibrary() {
        val clickMan = clickMan { context = mapOf("os" to mapOf("name" to "Android", "version" to "16"), "locale" to "en-US") }

        clickMan.track("app_opened")
        clickMan.setContext(mapOf("locale" to "ru-RU"))
        clickMan.track("export_completed")
        clickMan.flush()

        val (first, second) = server.events.map { it.child("context") }
        assertEquals("Android", first?.child("os")?.text("name"))
        assertEquals("en-US", first?.text("locale"))
        assertEquals(buildJsonObject { put("name", "clickman-kotlin"); put("version", ClickMan.VERSION) }, first?.child("library"))
        assertEquals(listOf("locale", "library"), second?.keys?.toList())
        assertEquals("ru-RU", second?.text("locale"))
    }

    @Test
    fun identifyAndResetSetTheActorOfLaterEvents() {
        val clickMan = clickMan()

        clickMan.identify("42")
        clickMan.track("signed_in")
        clickMan.reset()
        clickMan.track("signed_out")
        clickMan.flush()

        assertEquals(listOf("42", "*"), server.events.map { it.text("externalId") })
    }

    @Test
    fun traitsRideInTheContextUntilRemovedOrReset() {
        val clickMan = clickMan()

        clickMan.setTraits(mapOf("plan" to "pro"))
        clickMan.track("export_completed")
        clickMan.setTraits(mapOf("plan" to null))
        clickMan.track("paywall_viewed")
        clickMan.setTraits(mapOf("plan" to "max"))
        clickMan.reset()
        clickMan.track("signed_out")
        clickMan.flush()

        assertEquals(
            listOf(buildJsonObject { put("plan", "pro") }, null, null),
            server.events.map { it.child("context")?.child("traits") },
        )
    }

    @Test
    fun aLaunchIsAnInstallThenAnOpenAndANewBuildAnUpdate() {
        clickMan().apply {
            appLaunched("1.40", "140")
            close()
        }
        clickMan().apply {
            appLaunched("1.40", "140")
            close()
        }
        val clickMan = clickMan()
        clickMan.appLaunched("1.41", "141")
        clickMan.flush()

        assertEquals(listOf("app_installed", "app_opened", "app_opened", "app_updated", "app_opened"), sent())
        assertEquals(
            buildJsonObject { put("version", "1.41"); put("build", "141"); put("previous_version", "1.40"); put("previous_build", "140") },
            server.events[3].child("properties"),
        )
    }

    @Test
    fun aFailedSendKeepsTheEventsUntilARetryDeliversThem() {
        server.status = 503
        val clickMan = clickMan()

        clickMan.track("export_completed")
        clickMan.flush()
        clickMan.flush()
        assertEquals(1, server.requests.size)
        assertEquals(1, clickMan.pendingEvents)
        server.status = 202
        clock.advance(6.seconds)
        clickMan.flush()

        assertEquals(2, server.requests.size)
        assertEquals(0, clickMan.pendingEvents)
    }

    @Test
    fun aRefusedBatchIsDropped() {
        server.status = 400
        val clickMan = clickMan()

        clickMan.track("export_completed")
        clickMan.flush()

        assertEquals(1, server.requests.size)
        assertEquals(0, clickMan.pendingEvents)
    }

    @Test
    fun theQueueKeepsOnlyTheNewestMaxQueueEvents() {
        val clickMan = clickMan { maxQueue = 3 }

        for (event in listOf("e1", "e2", "e3", "e4", "e5")) clickMan.track(event)
        assertEquals(3, clickMan.pendingEvents)
        clickMan.flush()

        assertEquals(listOf("e3", "e4", "e5"), sent())
    }

    @Test
    fun reopeningKeepsTheEventsAndTheIdentity() {
        server.status = 503
        clickMan().apply {
            identify("42")
            setTraits(mapOf("plan" to "pro"))
            track("export_completed")
            flush()
            close()
        }
        server.status = 202

        val clickMan = clickMan()
        clickMan.track("paywall_viewed")
        assertEquals(2, clickMan.pendingEvents)
        clickMan.flush()

        assertEquals(listOf("export_completed", "export_completed", "paywall_viewed"), sent())
        assertEquals(listOf("42"), server.events.map { it.text("externalId") }.distinct())
        assertEquals(buildJsonObject { put("plan", "pro") }, server.events.last().child("context")?.child("traits"))
    }

    private val oldCoreState = mapOf(
        "external_id" to "42",
        "traits" to """{"plan":"pro"}""",
        "app_version" to "1.40",
        "app_build" to "140",
        "context" to """{"locale":"en-US"}""",
        "lease_batch_id" to "7",
        "next_attempt_at" to "${TestClock.START + 600_000}",
    )

    private val oldCoreBody = """{"type":"track","messageId":"01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f","event":"left_behind",""" +
        """"externalId":"42","timestamp":"2026-09-23T15:03:59.004Z","properties":{},"context":{}}"""

    @Test
    fun aStoreOfTheOldCoreIsAdoptedAndItsEventSent() {
        createOldCoreStore(storage, oldCoreState, oldCoreBody)

        val clickMan = clickMan()
        clickMan.appLaunched("1.40", "140")
        clickMan.track("after_upgrade")
        clickMan.flush()
        clickMan.close()

        assertEquals(listOf("left_behind", "app_opened", "after_upgrade"), sent())
        assertEquals(Json.parseToJsonElement(oldCoreBody), server.events.first())
        assertEquals(listOf("42"), server.events.map { it.text("externalId") }.distinct())
        assertEquals(buildJsonObject { put("plan", "pro") }, server.events.last().child("context")?.child("traits"))
        assertEquals(0L, inspect(storage) { it.long("SELECT count(*) FROM sqlite_master WHERE name IN ('state', 'events_batch')") })
        assertEquals(1L, inspect(storage) { it.long("PRAGMA user_version") })
    }

    @Test
    fun aStoreOfANewerClickManIsRefused() {
        inspect(storage) { it.exec("PRAGMA user_version = 2") }

        val error = assertFailsWith<ClickManException> { clickMan() }

        assertTrue(error.message.orEmpty().contains("newer ClickMan"), error.message)
    }

    @Test
    fun anEventThatBreaksTheRulesIsLoggedAsSevereAndNotStored() {
        val clickMan = clickMan()

        val records = logged {
            clickMan.track("")
            clickMan.track("a".repeat(201))
            clickMan.track("export_completed", mapOf("ratio" to Double.NaN))
            clickMan.identify("")
        }
        clickMan.track("paywall_viewed")
        clickMan.flush()

        assertEquals(listOf(Level.SEVERE, Level.SEVERE, Level.SEVERE, Level.SEVERE), records.map { it.level })
        assertTrue(records[0].message.contains(Validation.EVENT_RULE), records[0].message)
        assertTrue(records[3].message.contains(Validation.EXTERNAL_ID_RULE), records[3].message)
        assertEquals(listOf("paywall_viewed"), sent())
        assertEquals("*", server.events.single().text("externalId"))
    }

    @Test
    fun callsAfterCloseAreLoggedAndTouchNothing() {
        val clickMan = clickMan()
        clickMan.close()

        val records = logged {
            clickMan.track("export_completed")
            clickMan.identify("42")
            clickMan.setTraits(mapOf("plan" to "pro"))
            clickMan.flush()
            clickMan.flushInBackground()
            assertEquals(0, clickMan.pendingEvents)
        }

        assertEquals(6, records.size)
        assertTrue(records.all { it.message.contains("closed") }, records.joinToString { it.message })
        assertTrue(server.requests.isEmpty())
    }

    @Test
    fun aDueBatchIsSentWithoutAFlush() {
        val clickMan = clickMan(pollInterval = 50.milliseconds) { flushAt = 2 }

        clickMan.track("export_completed")
        clickMan.track("paywall_viewed")

        eventually("the due batch to leave the queue") { clickMan.pendingEvents == 0 }
        assertEquals(listOf("export_completed", "paywall_viewed"), sent())
    }

    @Test
    fun aFlushInTheBackgroundSendsWithoutWaiting() {
        val clickMan = clickMan()

        clickMan.track("app_backgrounded")
        clickMan.flushInBackground()

        eventually("the background flush") { sent() == listOf("app_backgrounded") }
    }

    @Test
    fun aConfigurationThatCannotWorkIsRefused() {
        for (configure in listOf<ClickMan.Configuration.() -> Unit>({ flushAt = 0 }, { maxQueue = 0 }, { flushInterval = Duration.ZERO })) {
            assertFailsWith<IllegalArgumentException> { clickMan(configure = configure) }
        }
    }
}
