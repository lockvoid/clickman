package com.lockvoid.clickman

import java.util.UUID
import kotlin.random.Random

/** RFC 9562 version 7: 48 bits of Unix milliseconds, the version, the RFC 4122 variant and 74 random bits. */
internal object UUIDv7 {
    private const val VERSION = 0x7000L
    private const val RFC_4122_VARIANT = Long.MIN_VALUE

    fun generate(millis: Long, random: Random): UUID {
        val high = (millis shl 16) or VERSION or random.nextLong(1L shl 12)
        val low = (random.nextLong() ushr 2) or RFC_4122_VARIANT
        return UUID(high, low)
    }
}
