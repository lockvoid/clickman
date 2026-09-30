package com.lockvoid.clickman

import java.io.File
import java.nio.file.Files
import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.DurationUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Every case of the shared client fixtures in protocol/fixtures (protocol/README.md). */
class ConformanceTest {
    private val directory: File = Files.createTempDirectory("clickman-conformance").toFile()
    private val none = JsonObject(emptyMap())

    @AfterTest
    fun tearDown() {
        directory.deleteRecursively()
    }

    private fun cases(fixture: String): List<JsonObject> {
        val file = File(System.getProperty("clickman.fixtures"), fixture)
        val cases = Json.parseToJsonElement(file.readText()).jsonObject.children("cases")
        assertTrue(cases.isNotEmpty(), "$file has no cases")
        return cases
    }

    private fun <T> withStore(name: String, work: (Queue, Tracker) -> T): T =
        openQueue(File(directory, "$name.sqlite")).use { queue -> work(queue, Tracker(queue, 10_000, { TestClock.START }, Random(9))) }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.int(key: String): Int = getValue(key).jsonPrimitive.int

    private fun release(json: JsonObject) = Release(json.string("version"), json.string("build"))

    @Test
    fun events() = withStore("events") { queue, tracker ->
        for (case in cases("events.json")) {
            val value = case.string("value")
            val stored = when (val field = case.string("field")) {
                "event" -> storesEvent(queue, tracker, value)
                "externalId" -> storesExternalId(queue, tracker, value)
                else -> fail("${case.string("name")}: no field $field")
            }
            assertEquals(case.getValue("valid").jsonPrimitive.boolean, stored, case.string("name"))
        }
    }

    private fun storesEvent(queue: Queue, tracker: Tracker, name: String): Boolean {
        val before = queue.transaction { it.count() }
        try {
            tracker.track(name, none)
        } catch (refusal: ClickManException) {
            assertEquals(Validation.EVENT_RULE, refusal.message)
        }
        return queue.transaction { it.count() } == before + 1
    }

    private fun storesExternalId(queue: Queue, tracker: Tracker, id: String): Boolean {
        tracker.identify("someone-else")
        try {
            tracker.identify(id)
        } catch (refusal: ClickManException) {
            assertEquals(Validation.EXTERNAL_ID_RULE, refusal.message)
        }
        return queue.transaction { it.identity() }.externalId == id
    }

    @Test
    fun traits() = withStore("traits") { queue, tracker ->
        for (case in cases("traits.json")) {
            queue.transaction { it.setTraits(case.getValue("stored").jsonObject) }
            tracker.setTraits(case.getValue("changes").jsonObject)
            assertEquals(case.getValue("traits").jsonObject, queue.transaction { it.identity() }.traits, case.string("name"))
        }
    }

    @Test
    fun lifecycle() {
        for ((index, case) in cases("lifecycle.json").withIndex()) {
            val recorded = withStore("lifecycle-$index") { queue, tracker ->
                (case.getValue("last") as? JsonObject)?.let { last -> queue.transaction { it.setRelease(release(last)) } }
                tracker.launch(release(case.getValue("launch").jsonObject))
                queue.bodies().map { buildJsonObject { put("event", it.getValue("event")); put("properties", it.getValue("properties")) } }
            }
            assertEquals(case.getValue("events").jsonArray.toList(), recorded, case.string("name"))
        }
    }

    @Test
    fun batches() {
        for (case in cases("batches.json")) {
            val bodies = case.getValue("bodies").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(case.int("taken"), Batch.cut(bodies, case.int("maxEvents"), case.int("maxBytes")), case.string("name"))
        }
    }

    @Test
    fun outcomes() {
        for (case in cases("outcomes.json")) {
            assertEquals(case.string("outcome"), Outcome.of(case.int("status")).name.lowercase(), case.string("name"))
        }
    }

    @Test
    fun backoff() {
        val random = Random(5)
        for (case in cases("backoff.json")) {
            val name = case.string("name")
            val failures = case.int("failures")
            val retryAfter = case.getValue("retryAfter").let { if (it == JsonNull) null else it.jsonPrimitive.double.seconds }
            val (min, max) = case.getValue("min").jsonPrimitive.double to case.getValue("max").jsonPrimitive.double
            val drawn = List(1_000) { Backoff.delay(failures, retryAfter, random).seconds() }
            assertTrue(drawn.all { it in min..max }, "$name: ${drawn.minOrNull()}..${drawn.maxOrNull()} outside $min..$max")
            assertClose(min, Backoff.delay(failures, retryAfter, EdgeRandom(high = false)).seconds(), "$name, the low end")
            assertClose(max, Backoff.delay(failures, retryAfter, EdgeRandom(high = true)).seconds(), "$name, the high end")
        }
    }

    private fun Duration.seconds(): Double = toDouble(DurationUnit.SECONDS)

    private fun assertClose(expected: Double, actual: Double, message: String) {
        assertTrue(abs(expected - actual) < 0.001, "$message: $actual is not $expected")
    }
}
