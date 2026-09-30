package com.lockvoid.clickman

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class TrackerTest {
    private val directory: File = Files.createTempDirectory("clickman-tracker").toFile()
    private val queue = openQueue(File(directory, "queue.sqlite"))
    private val clock = TestClock()
    private val tracker = Tracker(queue, maxQueue = 3, clock = { clock.millis }, random = Random(1))
    private val none = JsonObject(emptyMap())
    private val library = buildJsonObject {
        put("name", "clickman-kotlin")
        put("version", ClickMan.VERSION)
    }

    @AfterTest
    fun tearDown() {
        queue.close()
        directory.deleteRecursively()
    }

    @Test
    fun anEventIsStampedWithANewMessageIdTheActorTheTimeAndTheContext() {
        tracker.track("export_completed", buildJsonObject { put("format", "mp4") })

        val body = queue.bodies().single()
        val messageId = UUID.fromString(body.text("messageId"))
        assertEquals(listOf("type", "messageId", "event", "externalId", "timestamp", "properties", "context"), body.keys.toList())
        assertEquals("track", body.text("type"))
        assertEquals(7, messageId.version())
        assertEquals(clock.millis, messageId.mostSignificantBits ushr 16)
        assertEquals("export_completed", body.text("event"))
        assertEquals("*", body.text("externalId"))
        assertEquals("2026-09-30T12:00:00.123Z", body.text("timestamp"))
        assertEquals(buildJsonObject { put("format", "mp4") }, body.child("properties"))
        assertEquals(buildJsonObject { put("library", library) }, body.child("context"))
        assertEquals(clock.millis, queue.transaction { it.backlog() }?.oldest)
    }

    @Test
    fun theHostContextIsReplacedWhileTheLibraryStays() {
        tracker.setContext(buildJsonObject { put("locale", "en-US") })
        tracker.track("a", none)
        tracker.setContext(buildJsonObject { putJsonObject("os") { put("name", "Android") }; put("library", "theirs") })
        tracker.track("b", none)

        assertEquals(
            listOf(
                buildJsonObject { put("locale", "en-US"); put("library", library) },
                buildJsonObject { putJsonObject("os") { put("name", "Android") }; put("library", library) },
            ),
            queue.bodies().map { it.child("context") },
        )
    }

    @Test
    fun theTraitsOfTheMomentJoinTheContextOnlyWhenThereAreAny() {
        tracker.track("before", none)
        tracker.setTraits(buildJsonObject { put("plan", "pro") })
        tracker.track("during", none)
        tracker.setTraits(JsonObject(mapOf("plan" to JsonNull)))
        tracker.track("after", none)

        assertEquals(
            listOf(null, buildJsonObject { put("plan", "pro") }, null),
            queue.bodies().map { it.child("context")?.child("traits") },
        )
    }

    @Test
    fun anInvalidNameIsRefusedAndNothingIsStored() {
        for (name in listOf("", "a".repeat(201), "export\ncompleted")) {
            val error = assertFailsWith<ClickManException> { tracker.track(name, none) }
            assertEquals(Validation.EVENT_RULE, error.message)
        }

        assertEquals(0, queue.transaction { it.count() })
    }

    @Test
    fun anInvalidExternalIdIsRefusedAndTheActorKept() {
        tracker.identify("42")

        assertFailsWith<ClickManException> { tracker.identify("") }
        assertFailsWith<ClickManException> { tracker.identify("x".repeat(257)) }
        tracker.track("still_42", none)

        assertEquals("42", queue.bodies().single().text("externalId"))
    }

    @Test
    fun aResetMakesLaterEventsAnonymousAndForgetsTheTraits() {
        tracker.identify("42")
        tracker.setTraits(buildJsonObject { put("plan", "pro") })
        tracker.track("signed_in", none)
        tracker.reset()
        tracker.track("signed_out", none)

        val (signedIn, signedOut) = queue.bodies()
        assertEquals("42", signedIn.text("externalId"))
        assertEquals("*", signedOut.text("externalId"))
        assertNull(signedOut.child("context")?.child("traits"))
    }

    @Test
    fun aLaunchQueuesItsEventsAndRemembersTheRelease() {
        tracker.launch(Release("1.40", "140"))
        clock.advance(60.seconds)
        tracker.launch(Release("1.40", "140"))

        assertEquals(listOf("app_installed", "app_opened", "app_opened"), queue.bodies().map { it.text("event") })
        assertEquals(Release("1.40", "140"), queue.transaction { it.identity() }.release)
        assertEquals("2026-09-30T12:01:00.123Z", queue.bodies().last().text("timestamp"))
    }

    @Test
    fun trackingKeepsOnlyTheNewestMaxQueueEvents() {
        for (name in listOf("1", "2", "3", "4")) tracker.track(name, none)

        assertEquals(listOf("2", "3", "4"), queue.bodies().map { it.text("event") })
    }
}
