package com.lockvoid.clickman

import kotlin.random.Random
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Records events: a name that passes the rules, stamped with a new message id,
 * the stored actor, the time and the context, queued with the traits of its
 * moment. The context lives in memory; the identity lives in the queue.
 */
internal class Tracker(
    private val queue: Queue,
    private val maxQueue: Int,
    private val clock: () -> Long,
    private val random: Random,
) {
    @Volatile
    private var context: JsonObject = JsonObject(LIBRARY)

    fun setContext(host: JsonObject) {
        context = JsonObject(host + LIBRARY)
    }

    fun track(event: String, properties: JsonObject) {
        if (!Validation.isEvent(event)) throw ClickManException(Validation.EVENT_RULE)
        val now = clock()
        queue.transaction { it.insert(now, body(it.identity(), event, properties, now), maxQueue) }
    }

    fun identify(externalId: String) {
        if (!Validation.isExternalId(externalId)) throw ClickManException(Validation.EXTERNAL_ID_RULE)
        queue.transaction { it.setExternalId(externalId) }
    }

    fun setTraits(changes: JsonObject) {
        queue.transaction { it.setTraits(Traits.merge(it.identity().traits, changes)) }
    }

    fun reset() {
        queue.transaction { it.reset() }
    }

    fun launch(release: Release) {
        val now = clock()
        queue.transaction { tx ->
            val identity = tx.identity()
            for (event in Launch.events(identity.release, release)) {
                tx.insert(now, body(identity, event.name, event.properties, now), maxQueue)
            }
            tx.setRelease(release)
        }
    }

    private fun body(identity: Identity, event: String, properties: JsonObject, now: Long): String =
        EventBody.encode(UUIDv7.generate(now, random), event, identity.externalId, now, properties, contextWith(identity.traits))

    private fun contextWith(traits: JsonObject): JsonObject =
        if (traits.isEmpty()) context else JsonObject(context + ("traits" to traits))

    private companion object {
        val LIBRARY = mapOf(
            "library" to buildJsonObject {
                put("name", "clickman-kotlin")
                put("version", ClickMan.VERSION)
            },
        )
    }
}
