package com.lockvoid.clickman

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** A version and build of the host app. */
internal data class Release(val version: String, val build: String)

/** The events a launch records (lifecycle.json). */
internal object Launch {
    class Event(val name: String, val properties: JsonObject)

    private val OPENED = Event("app_opened", buildJsonObject { put("from_background", false) })

    /** The events of launching [launch] after [last], the last launch the store remembers. */
    fun events(last: Release?, launch: Release): List<Event> = listOfNotNull(change(last, launch), OPENED)

    private fun change(last: Release?, launch: Release): Event? = when (last) {
        null -> Event("app_installed", buildJsonObject {
            put("version", launch.version)
            put("build", launch.build)
        })
        launch -> null
        else -> Event("app_updated", buildJsonObject {
            put("version", launch.version)
            put("build", launch.build)
            put("previous_version", last.version)
            put("previous_build", last.build)
        })
    }
}
