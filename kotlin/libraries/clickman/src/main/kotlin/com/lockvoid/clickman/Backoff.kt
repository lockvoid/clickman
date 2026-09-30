package com.lockvoid.clickman

import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** The wait before the next attempt after consecutive failures (backoff.json). */
internal object Backoff {
    private const val FIRST_SECONDS = 5.0
    private const val MAX_SECONDS = 600.0

    fun delay(failures: Int, retryAfter: Duration?, random: Random): Duration {
        val doubled = min(FIRST_SECONDS * 2.0.pow(failures - 1), MAX_SECONDS)
        val jittered = (doubled * random.nextDouble(0.8, 1.2)).seconds
        return maxOf(jittered, retryAfter ?: Duration.ZERO)
    }
}
