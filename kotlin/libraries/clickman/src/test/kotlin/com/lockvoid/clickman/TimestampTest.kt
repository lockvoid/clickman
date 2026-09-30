package com.lockvoid.clickman

import java.time.Instant
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals

class TimestampTest {
    private fun millis(text: String) = Instant.parse(text).toEpochMilli()

    @Test
    fun aTimeIsUtcWithThreeDigitsOfMilliseconds() {
        assertEquals("2026-09-30T12:00:00.123Z", Timestamp.format(millis("2026-09-30T12:00:00.123Z")))
        assertEquals("2026-09-30T12:00:00.100Z", Timestamp.format(millis("2026-09-30T12:00:00.1Z")))
        assertEquals("1970-01-01T00:00:00.000Z", Timestamp.format(0))
    }

    @Test
    fun theDeviceTimeZoneChangesNothing() {
        val zone = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Kiritimati"))
            assertEquals("2026-09-30T23:59:59.999Z", Timestamp.format(millis("2026-09-30T23:59:59.999Z")))
        } finally {
            TimeZone.setDefault(zone)
        }
    }
}
