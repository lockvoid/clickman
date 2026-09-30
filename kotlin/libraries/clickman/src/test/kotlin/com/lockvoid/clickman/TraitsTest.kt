package com.lockvoid.clickman

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class TraitsTest {
    private val stored = buildJsonObject {
        put("plan", "pro")
        put("seats", 3)
    }

    @Test
    fun aChangeReplacesItsTraitAndKeepsTheOthers() {
        val merged = Traits.merge(stored, buildJsonObject { put("plan", "team") })

        assertEquals(buildJsonObject { put("plan", "team"); put("seats", 3) }, merged)
    }

    @Test
    fun nullRemovesATraitAndAnUnknownNullChangesNothing() {
        assertEquals(buildJsonObject { put("seats", 3) }, Traits.merge(stored, JsonObject(mapOf("plan" to JsonNull))))
        assertEquals(stored, Traits.merge(stored, JsonObject(mapOf("team" to JsonNull))))
    }

    @Test
    fun aNestedValueIsReplacedWhole() {
        val team = JsonObject(mapOf("team" to buildJsonObject { put("id", 1); put("size", 2) }))
        val changes = JsonObject(mapOf("team" to buildJsonObject { put("id", 2) }))

        assertEquals(changes, Traits.merge(team, changes))
    }

    @Test
    fun removingTheLastTraitLeavesNone() {
        val merged = Traits.merge(JsonObject(mapOf("plan" to JsonPrimitive("pro"))), JsonObject(mapOf("plan" to JsonNull)))

        assertEquals(JsonObject(emptyMap()), merged)
    }
}
