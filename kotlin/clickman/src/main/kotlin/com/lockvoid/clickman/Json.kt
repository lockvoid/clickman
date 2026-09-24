package com.lockvoid.clickman

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Date
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Properties, traits and context as JSON; dates as ISO 8601, anything else unknown as its string. */
internal fun Map<String, Any?>.toJson(): String = toJsonElement().toString()

private fun Any?.toJsonElement(): JsonElement =
    when (this) {
        null -> JsonNull
        is JsonElement -> this
        is String -> JsonPrimitive(this)
        is Number -> JsonPrimitive(this)
        is Boolean -> JsonPrimitive(this)
        is Map<*, *> -> JsonObject(entries.associate { (key, value) -> key.toString() to value.toJsonElement() })
        is Iterable<*> -> JsonArray(map { it.toJsonElement() })
        is Array<*> -> JsonArray(map { it.toJsonElement() })
        is Instant -> JsonPrimitive(DateTimeFormatter.ISO_INSTANT.format(this))
        is Date -> JsonPrimitive(DateTimeFormatter.ISO_INSTANT.format(toInstant()))
        is Enum<*> -> JsonPrimitive(name)
        else -> JsonPrimitive(toString())
    }
