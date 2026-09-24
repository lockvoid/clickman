package com.lockvoid.clickman

import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class ClickManTest {
    private lateinit var server: StubServer
    private lateinit var directory: File
    private val opened = mutableListOf<ClickMan>()

    @BeforeTest
    fun setUp() {
        server = StubServer.start()
        directory = Files.createTempDirectory("clickman-kotlin").toFile()
    }

    @AfterTest
    fun tearDown() {
        opened.forEach { it.close() }
        server.stop()
        directory.deleteRecursively()
    }

    private fun clickMan(context: Map<String, Any?> = emptyMap()): ClickMan {
        val configuration = ClickMan.Configuration(server.endpoint, "android-key", File(directory, "queue.sqlite"))
        configuration.pollInterval = 1.hours
        configuration.context = context
        return ClickMan(configuration).also { opened += it }
    }

    private fun JsonObject.text(key: String): String? = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.child(key: String): JsonObject? = get(key) as? JsonObject

    @Test
    fun trackedEventsAreSentAsOneGzippedBatch() {
        val clickMan = clickMan()

        clickMan.track("export_completed", mapOf("format" to "mp4", "duration" to 32.5))
        clickMan.track("paywall_viewed")
        clickMan.flush()

        val request = server.requests.single()
        assertEquals("/v1/batch", request.path)
        assertEquals("Bearer android-key", request.headers["authorization"])
        assertEquals("gzip", request.headers["content-encoding"])
        assertNotNull(request.batch.text("sentAt"))
        assertEquals(listOf("export_completed", "paywall_viewed"), server.events.map { it.text("event") })
        val first = server.events.first()
        assertEquals("track", first.text("type"))
        assertEquals("*", first.text("externalId"))
        assertEquals(buildJsonObject { put("format", "mp4"); put("duration", 32.5) }, first.child("properties"))
        assertEquals(0, clickMan.pendingEvents)
    }

    @Test
    fun everyEventCarriesTheHostContextAndTheLibrary() {
        val clickMan = clickMan(mapOf("os" to mapOf("name" to "Android", "version" to "16"), "locale" to "en-US"))

        clickMan.track("app_opened")
        clickMan.flush()

        val context = server.events.single().child("context")
        assertEquals("Android", context?.child("os")?.text("name"))
        assertEquals("en-US", context?.text("locale"))
        assertEquals("clickman-kotlin", context?.child("library")?.text("name"))
        assertEquals(ClickMan.VERSION, context?.child("library")?.text("version"))
    }

    @Test
    fun aLaunchIsReportedAsAnInstallAndThenAnOpenAndANewBuildAsAnUpdate() {
        clickMan().apply {
            appLaunched("1.40", "140")
            close()
        }
        val clickMan = clickMan()
        clickMan.appLaunched("1.41", "141")
        clickMan.flush()

        assertEquals(
            listOf(
                "app_installed" to buildJsonObject { put("version", "1.40"); put("build", "140") },
                "app_opened" to buildJsonObject { put("from_background", false) },
                "app_updated" to buildJsonObject {
                    put("version", "1.41")
                    put("build", "141")
                    put("previous_version", "1.40")
                    put("previous_build", "140")
                },
                "app_opened" to buildJsonObject { put("from_background", false) },
            ),
            server.events.map { it.text("event") to it.child("properties") },
        )
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
    fun datesUuidsAndNullsAreSentAsJson() {
        val clickMan = clickMan()
        val id = UUID.fromString("0192d7a4-0000-7000-8000-000000000001")

        clickMan.track("export_completed", mapOf("at" to Instant.parse("2026-09-23T12:00:00.250Z"), "id" to id, "missing" to null, "sizes" to listOf(1, 2)))
        clickMan.flush()

        val properties = server.events.single().child("properties")
        assertEquals("2026-09-23T12:00:00.250Z", properties?.text("at"))
        assertEquals(id.toString(), properties?.text("id"))
        assertEquals(JsonNull, properties?.get("missing"))
        assertEquals("[1,2]", properties?.get("sizes").toString())
    }

    @Test
    fun aFailedSendKeepsTheEventsForARetry() {
        server.status = 503
        server.retryAfter = "120"
        val clickMan = clickMan()

        clickMan.track("export_completed")
        clickMan.flush()
        clickMan.flush()

        assertEquals(1, server.requests.size)
        assertEquals(1, clickMan.pendingEvents)
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
    fun theQueueSurvivesARestartOfTheApp() {
        server.status = 503
        clickMan().apply {
            identify("42")
            track("export_completed")
            flush()
            close()
        }
        server.status = 202

        val clickMan = clickMan()
        clickMan.track("paywall_viewed")

        assertEquals(2, clickMan.pendingEvents)
        assertEquals("42", server.events.single().text("externalId"))
    }

    @Test
    fun anEventTheCoreRefusesIsDroppedWithoutHarm() {
        val clickMan = clickMan()

        clickMan.track("")
        clickMan.track("export_completed", mapOf("ratio" to Double.NaN))
        clickMan.track("paywall_viewed")
        clickMan.flush()

        assertEquals(listOf("paywall_viewed"), server.events.map { it.text("event") })
    }

    @Test
    fun callsAfterCloseAreIgnoredInsteadOfTouchingTheFreedQueue() {
        val clickMan = clickMan()
        clickMan.close()

        clickMan.track("export_completed")
        clickMan.identify("42")
        clickMan.setTraits(mapOf("plan" to "pro"))
        clickMan.flush()
        clickMan.flushInBackground()

        assertEquals(0, clickMan.pendingEvents)
        assertTrue(server.requests.isEmpty())
    }
}
