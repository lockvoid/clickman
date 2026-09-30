package com.lockvoid.clickman

import java.util.zip.GZIPInputStream
import kotlin.test.Test
import kotlin.test.assertEquals

class BatchTest {
    @Test
    fun aBatchTakesTheOldestEventsUpToTheEventLimit() {
        assertEquals(2, Batch.cut(listOf("{}", "{}", "{}"), maxEvents = 2, maxBytes = 900_000))
        assertEquals(3, Batch.cut(listOf("{}", "{}", "{}"), maxEvents = 100, maxBytes = 900_000))
        assertEquals(0, Batch.cut(emptyList(), maxEvents = 100, maxBytes = 900_000))
    }

    @Test
    fun theByteLimitCountsTheCommasBetweenBodies() {
        assertEquals(2, Batch.cut(listOf("{}", "{}", "{}"), maxEvents = 100, maxBytes = 5))
        assertEquals(3, Batch.cut(listOf("{}", "{}", "{}"), maxEvents = 100, maxBytes = 8))
    }

    @Test
    fun bytesAreUtf8Bytes() {
        assertEquals(1, Batch.cut(listOf("\"é\"", "\"é\""), maxEvents = 100, maxBytes = 8))
        assertEquals(2, Batch.cut(listOf("\"é\"", "\"é\""), maxEvents = 100, maxBytes = 9))
    }

    @Test
    fun anOversizedOldestEventGoesAlone() {
        val large = "\"${"x".repeat(Batch.MAX_BYTES)}\""

        assertEquals(1, Batch.cut(listOf(large, "{}"), Batch.MAX_EVENTS, Batch.MAX_BYTES))
    }

    @Test
    fun theBodiesAreSentVerbatimUnderTheSendingTime() {
        val bodies = listOf("""{"event":"a", "spaced": true}""", """{"event":"b"}""")

        val json = GZIPInputStream(Batch.encode(TestClock.START, bodies).inputStream()).readBytes().decodeToString()

        assertEquals("""{"sentAt":"2026-09-30T12:00:00.123Z","batch":[{"event":"a", "spaced": true},{"event":"b"}]}""", json)
    }
}
