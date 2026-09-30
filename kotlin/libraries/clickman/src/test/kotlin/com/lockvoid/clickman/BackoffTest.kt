package com.lockvoid.clickman

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class BackoffTest {
    private val low = EdgeRandom(high = false)
    private val high = EdgeRandom(high = true)

    @Test
    fun theDelayStartsAtFiveSecondsAndDoublesPerFailure() {
        assertEquals(4.seconds, Backoff.delay(1, null, low))
        assertEquals(8.seconds, Backoff.delay(2, null, low))
        assertEquals(256.seconds, Backoff.delay(7, null, low))
        assertTrue(Backoff.delay(1, null, high) in 5.99.seconds..6.seconds)
    }

    @Test
    fun theDelayStopsGrowingAtTenMinutes() {
        assertEquals(480.seconds, Backoff.delay(8, null, low))
        assertEquals(480.seconds, Backoff.delay(10_000, null, low))
        assertTrue(Backoff.delay(10_000, null, high) in 719.seconds..720.seconds)
    }

    @Test
    fun theJitterSpreadsTheDelay() {
        val random = Random(1)
        val delays = List(1_000) { Backoff.delay(3, null, random) }

        assertTrue(delays.all { it in 16.seconds..24.seconds })
        assertTrue(delays.toSet().size > 900)
    }

    @Test
    fun aLongerRetryAfterWinsExactlyAndAShorterOneLoses() {
        assertEquals(30.seconds, Backoff.delay(1, 30.seconds, high))
        assertEquals(16.seconds, Backoff.delay(3, 2.seconds, low))
        assertEquals(6_001.milliseconds, Backoff.delay(1, 6_001.milliseconds, high))
    }
}
