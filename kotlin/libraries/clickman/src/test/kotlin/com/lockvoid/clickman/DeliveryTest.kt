package com.lockvoid.clickman

import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.util.logging.Level
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import org.junit.Rule
import org.junit.rules.Timeout

class DeliveryTest {
    @get:Rule
    val timeout: Timeout = Timeout.seconds(60)

    private val directory: File = Files.createTempDirectory("clickman-delivery").toFile()
    private val queue = openQueue(File(directory, "queue.sqlite"))
    private val server = StubServer.start()
    private val clock = TestClock()
    private val delivery = deliveryTo(server.endpoint)

    private fun deliveryTo(endpoint: String) = Delivery(
        queue,
        Sender(endpoint, "key"),
        flushAt = 20,
        flushInterval = 30.seconds,
        clock = { clock.millis },
        random = EdgeRandom(high = false),
    )

    @AfterTest
    fun tearDown() {
        server.stop()
        queue.close()
        directory.deleteRecursively()
    }

    private fun track(count: Int, first: Int = 1) {
        queue.transaction { tx ->
            for (index in first until first + count) tx.insert(clock.millis, """{"event":"e$index"}""", maxQueue = 10_000)
        }
    }

    private fun batchSizes(): List<Int> = server.requests.map { it.batch.children("batch").size }

    private fun pending(): Int = queue.transaction { it.count() }

    private fun drainAfter(wait: Duration, force: Boolean = true) {
        clock.advance(wait)
        delivery.drain(force)
    }

    @Test
    fun nothingIsSentBeforeABatchIsDue() {
        track(19)

        delivery.drain(force = false)

        assertEquals(emptyList(), server.requests)
        assertEquals(19, pending())
    }

    @Test
    fun flushAtWaitingEventsMakeABatchDue() {
        track(20)

        delivery.drain(force = false)

        assertEquals(listOf(20), batchSizes())
        assertEquals(0, pending())
    }

    @Test
    fun anOldestEventThatWaitedTheFlushIntervalMakesABatchDue() {
        track(1)

        drainAfter(29_999.milliseconds, force = false)
        assertEquals(emptyList(), batchSizes())
        drainAfter(1.milliseconds, force = false)

        assertEquals(listOf(1), batchSizes())
    }

    @Test
    fun aForcedDrainSendsWhateverIsWaiting() {
        track(1)

        delivery.drain(force = true)

        assertEquals(listOf("e1"), server.events.map { it.text("event") })
        assertEquals(0, pending())
    }

    @Test
    fun aRefusedBatchLeavesTheQueueWithAWarning() {
        server.status = 400
        server.answer = """{"error":"malformed_batch","message":"not JSON"}"""
        track(2)

        val records = logged { delivery.drain(force = true) }

        assertEquals(0, pending())
        val warning = records.single { it.level == Level.WARNING }
        assertTrue(warning.message.contains("dropped 2 events") && warning.message.contains("malformed_batch"), warning.message)
    }

    @Test
    fun aFailedBatchStaysAndNothingIsSentBeforeItsBackoffPassed() {
        server.status = 503
        track(1)

        delivery.drain(force = true)
        drainAfter(3_999.milliseconds)
        assertEquals(1, server.requests.size)
        drainAfter(1.milliseconds)
        assertEquals(2, server.requests.size)
        drainAfter(7_999.milliseconds)
        assertEquals(2, server.requests.size)
        drainAfter(1.milliseconds)

        assertEquals(3, server.requests.size)
        assertEquals(1, pending())
    }

    @Test
    fun aLongerRetryAfterWins() {
        server.status = 429
        server.retryAfter = "120"
        track(1)

        delivery.drain(force = true)
        server.status = 202
        drainAfter(119_999.milliseconds)
        assertEquals(1, server.requests.size)
        drainAfter(1.milliseconds)

        assertEquals(2, server.requests.size)
        assertEquals(0, pending())
    }

    @Test
    fun aDeliveryStartsTheBackoffOver() {
        server.status = 503
        track(1)
        delivery.drain(force = true)
        drainAfter(4.seconds)
        server.status = 202
        drainAfter(8.seconds)
        track(1, first = 2)
        server.status = 503

        drainAfter(Duration.ZERO)
        drainAfter(4.seconds)

        assertEquals(5, server.requests.size)
    }

    @Test
    fun aDrainSendsBatchesUntilNothingIsDue() {
        track(115)

        delivery.drain(force = false)
        assertEquals(listOf(100), batchSizes())
        track(135, first = 116)
        delivery.drain(force = true)

        assertEquals(listOf(100, 100, 50), batchSizes())
        assertEquals((1..250).map { "e$it" }, server.events.map { it.text("event") })
    }

    @Test
    fun aFailedSendStopsTheDrain() {
        server.status = 500
        track(250)

        delivery.drain(force = true)

        assertEquals(listOf(100), batchSizes())
        assertEquals(250, pending())
    }

    @Test
    fun eventsOlderThanThirtyDaysAreDeletedUnsent() {
        track(1, first = 1)
        clock.advance(30.days + 1.milliseconds)
        track(1, first = 2)

        delivery.drain(force = true)

        assertEquals(listOf("e2"), server.events.map { it.text("event") })
        assertEquals(0, pending())
    }

    @Test
    fun anEventOfExactlyThirtyDaysIsStillSent() {
        track(1)
        clock.advance(30.days)

        delivery.drain(force = true)

        assertEquals(listOf("e1"), server.events.map { it.text("event") })
    }

    @Test
    fun aBatchIsCutAtItsByteLimit() {
        val padding = "x".repeat(400_000)
        queue.transaction { tx ->
            for (index in 1..3) tx.insert(clock.millis, """{"event":"e$index","padding":"$padding"}""", maxQueue = 10_000)
        }

        delivery.drain(force = true)

        assertEquals(listOf(2, 1), batchSizes())
    }

    @Test
    fun noAnswerIsARetryWithAWarning() {
        val port = ServerSocket(0).use { it.localPort }
        val unreachable = deliveryTo("http://127.0.0.1:$port")
        track(1)

        val records = logged { unreachable.drain(force = true) }

        assertEquals(1, pending())
        assertTrue(records.single { it.level == Level.WARNING }.message.contains("no answer from"))
    }
}
