package com.lockvoid.clickman

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

/** Traits merge key by key: a null removes one and a nested value replaces the old one whole (traits.json). */
internal object Traits {
    fun merge(stored: JsonObject, changes: JsonObject): JsonObject =
        JsonObject((stored + changes).filterValues { it != JsonNull })
}
