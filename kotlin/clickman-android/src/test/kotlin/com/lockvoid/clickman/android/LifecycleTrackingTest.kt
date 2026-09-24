package com.lockvoid.clickman.android

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.lockvoid.clickman.ClickMan
import com.lockvoid.clickman.StubServer
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class LifecycleTrackingTest {
    private lateinit var server: StubServer
    private lateinit var directory: File
    private lateinit var clickMan: ClickMan
    private val owner = object : LifecycleOwner {
        override val lifecycle: Lifecycle
            get() = error("the tracking does not read the owner")
    }

    @BeforeTest
    fun setUp() {
        server = StubServer.start()
        directory = Files.createTempDirectory("clickman-android").toFile()
        clickMan = ClickMan(ClickMan.Configuration(server.endpoint, "android-key", File(directory, "queue.sqlite")))
    }

    @AfterTest
    fun tearDown() {
        clickMan.close()
        server.stop()
        directory.deleteRecursively()
    }

    private fun tracking(tracksLifecycle: Boolean = true) =
        LifecycleTracking(clickMan, tracksLifecycle) { mapOf("os" to mapOf("name" to "Android")) }

    private fun eventually(what: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 10_000_000_000
        while (!condition()) {
            check(System.nanoTime() < deadline) { "timed out waiting for $what" }
            Thread.sleep(20)
        }
    }

    @Test
    fun theFirstStartIsTheLaunchAndIsNotReportedAgain() {
        tracking().onStart(owner)
        clickMan.flush()

        assertTrue(server.events.isEmpty())
    }

    @Test
    fun leavingSendsTheQueueAndReturningIsAnOpenFromTheBackground() {
        val tracking = tracking()
        clickMan.track("export_completed")

        tracking.onStart(owner)
        tracking.onStop(owner)
        eventually("the queue to be sent on leaving") { server.events.size == 2 }
        tracking.onStart(owner)
        clickMan.flush()

        assertEquals(
            listOf("export_completed", "app_backgrounded", "app_opened"),
            server.events.map { (it["event"] as JsonPrimitive).content },
        )
        assertEquals(buildJsonObject { put("from_background", true) }, server.events.last()["properties"])
    }

    @Test
    fun withoutLifecycleEventsLeavingStillSendsTheQueue() {
        val tracking = tracking(tracksLifecycle = false)
        clickMan.track("export_completed")

        tracking.onStart(owner)
        tracking.onStop(owner)
        eventually("the queue to be sent on leaving") { server.events.size == 1 }
        tracking.onStart(owner)
        clickMan.flush()

        assertEquals(listOf("export_completed"), server.events.map { (it["event"] as JsonPrimitive).content })
    }
}
