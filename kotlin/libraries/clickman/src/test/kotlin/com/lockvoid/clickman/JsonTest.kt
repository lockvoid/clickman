package com.lockvoid.clickman

import java.time.Instant
import java.util.Date
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

class JsonTest {
    @Test
    fun valuesBecomeTheirJson() {
        val json = mapOf(
            "text" to "mp4",
            "count" to 3,
            "ratio" to 32.5,
            "on" to true,
            "missing" to null,
            "sizes" to listOf(1, 2),
            "tags" to arrayOf("a", "b"),
            "nested" to mapOf(1 to mapOf("deep" to false)),
            "raw" to buildJsonObject { },
        ).toJsonObject()

        assertEquals(
            """{"text":"mp4","count":3,"ratio":32.5,"on":true,"missing":null,"sizes":[1,2],"tags":["a","b"],"nested":{"1":{"deep":false}},"raw":{}}""",
            json.toString(),
        )
    }

    @Test
    fun datesAreIso8601AndOtherValuesTheirText() {
        val instant = Instant.parse("2026-09-23T12:00:00.250Z")
        val id = UUID.fromString("0192d7a4-0000-7000-8000-000000000001")
        val json = mapOf("at" to instant, "on" to Date.from(instant), "unit" to TimeUnit.SECONDS, "id" to id).toJsonObject()

        assertEquals(JsonPrimitive("2026-09-23T12:00:00.250Z"), json["at"])
        assertEquals(JsonPrimitive("2026-09-23T12:00:00.250Z"), json["on"])
        assertEquals(JsonPrimitive("SECONDS"), json["unit"])
        assertEquals(JsonPrimitive(id.toString()), json["id"])
    }

    @Test
    fun aNumberJsonCannotCarryIsRefused() {
        for (number in listOf(Double.NaN, Double.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertFailsWith<ClickManException>("$number") { mapOf("ratio" to listOf(number)).toJsonObject() }
        }
    }
}
