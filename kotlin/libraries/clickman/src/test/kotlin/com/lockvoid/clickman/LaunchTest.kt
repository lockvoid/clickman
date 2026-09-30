package com.lockvoid.clickman

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class LaunchTest {
    private val opened = "app_opened" to buildJsonObject { put("from_background", false) }

    private fun events(last: Release?, launch: Release): List<Pair<String, JsonObject>> =
        Launch.events(last, launch).map { it.name to it.properties }

    @Test
    fun aLaunchTheStoreHasNeverSeenIsAnInstall() {
        assertEquals(
            listOf("app_installed" to buildJsonObject { put("version", "1.40"); put("build", "140") }, opened),
            events(null, Release("1.40", "140")),
        )
    }

    @Test
    fun theSameReleaseIsOnlyAnOpen() {
        assertEquals(listOf(opened), events(Release("1.40", "140"), Release("1.40", "140")))
    }

    @Test
    fun anotherVersionOrBuildIsAnUpdateFromTheLastOne() {
        val update = buildJsonObject {
            put("version", "1.40")
            put("build", "141")
            put("previous_version", "1.40")
            put("previous_build", "140")
        }

        assertEquals(listOf("app_updated" to update, opened), events(Release("1.40", "140"), Release("1.40", "141")))
    }
}
