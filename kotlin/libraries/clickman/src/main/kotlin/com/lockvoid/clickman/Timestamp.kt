package com.lockvoid.clickman

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** RFC 3339 in UTC with milliseconds, such as `2026-09-30T12:00:00.123Z`. */
internal object Timestamp {
    private val FORMAT: DateTimeFormatter =
        DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun format(millis: Long): String = FORMAT.format(Instant.ofEpochMilli(millis))
}
