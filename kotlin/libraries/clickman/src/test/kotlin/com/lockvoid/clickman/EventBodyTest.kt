package com.lockvoid.clickman

import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class EventBodyTest {
    private val messageId = UUID.fromString("01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f")
    private val timestamp = Instant.parse("2026-09-23T15:03:59.004Z").toEpochMilli()

    @Test
    fun aBodyIsTheTrackEventOfTheProtocol() {
        val properties = buildJsonObject {
            put("format", "mp4")
            put("duration", 32.5)
        }
        val context = buildJsonObject {
            putJsonObject("os") {
                put("name", "iOS")
                put("version", "26.1")
            }
        }

        assertEquals(
            """{"type":"track","messageId":"01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f","event":"export_completed",""" +
                """"externalId":"user_42","timestamp":"2026-09-23T15:03:59.004Z",""" +
                """"properties":{"format":"mp4","duration":32.5},"context":{"os":{"name":"iOS","version":"26.1"}}}""",
            EventBody.encode(messageId, "export_completed", "user_42", timestamp, properties, context),
        )
    }

    @Test
    fun textIsCarriedAsJsonStrings() {
        val event = "Экспорт \"готов\" \\ 👍"
        val body = EventBody.encode(messageId, event, "*", timestamp, JsonObject(emptyMap()), JsonObject(emptyMap()))

        assertEquals(event, Json.parseToJsonElement(body).jsonObject.text("event"))
    }
}
