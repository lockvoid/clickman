package com.lockvoid.clickman

import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** An event as it is queued and sent (docs/PROTOCOL.md, Event). */
internal object EventBody {
    fun encode(
        messageId: UUID,
        event: String,
        externalId: String,
        timestamp: Long,
        properties: JsonObject,
        context: JsonObject,
    ): String = buildJsonObject {
        put("type", "track")
        put("messageId", messageId.toString())
        put("event", event)
        put("externalId", externalId)
        put("timestamp", Timestamp.format(timestamp))
        put("properties", properties)
        put("context", context)
    }.toString()
}
