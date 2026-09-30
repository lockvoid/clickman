package com.lockvoid.clickman.e2e

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import com.lockvoid.clickman.ClickMan
import java.io.File
import java.util.Locale
import java.util.TimeZone
import kotlin.system.exitProcess
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The Kotlin client under the end-to-end suite: `<endpoint> <write-key> <store-path>`,
 * then one JSON command per line on stdin, one JSON answer per line on stdout.
 */
fun main(args: Array<String>) {
    if (args.size != 3) {
        System.err.println("usage: e2e-worker <endpoint> <write-key> <store-path>")
        exitProcess(2)
    }
    ClickMan(configuration(args[0], args[1], File(args[2]))).use { clickMan ->
        clickMan.appLaunched("e2e", "1")
        reply(buildJsonObject { put("ready", true); put("language", "kotlin") })
        while (true) {
            val line = readlnOrNull() ?: break
            reply(answer(clickMan, line))
        }
    }
}

private fun configuration(endpoint: String, writeKey: String, store: File) =
    ClickMan.Configuration(endpoint, writeKey, store, BundledSQLiteDriver()).apply {
        context = mapOf(
            "app" to mapOf("name" to "clickman-e2e-worker", "version" to "e2e", "build" to "1", "namespace" to "com.lockvoid.clickman.e2e"),
            "device" to mapOf("type" to "jvm"),
            "os" to mapOf("name" to System.getProperty("os.name"), "version" to System.getProperty("os.version")),
            "locale" to Locale.getDefault().toLanguageTag(),
            "timezone" to TimeZone.getDefault().id,
        )
    }

private fun answer(clickMan: ClickMan, line: String): JsonObject =
    try {
        perform(clickMan, Json.parseToJsonElement(line).jsonObject)
    } catch (error: Exception) {
        buildJsonObject { put("ok", false); put("error", error.toString()) }
    }

private fun perform(clickMan: ClickMan, input: JsonObject): JsonObject =
    when (val command = input.text("command")) {
        "identify" -> done { clickMan.identify(input.text("externalId")) }
        "traits" -> done { clickMan.setTraits(input.getValue("traits").jsonObject) }
        "track" -> done { clickMan.track(input.text("event"), input["properties"]?.jsonObject ?: JsonObject(emptyMap())) }
        "reset" -> done { clickMan.reset() }
        "flush" -> {
            clickMan.flush()
            pending(clickMan)
        }
        "pending" -> pending(clickMan)
        else -> throw IllegalArgumentException("unknown command \"$command\"")
    }

private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content

private inline fun done(work: () -> Unit): JsonObject {
    work()
    return buildJsonObject { put("ok", true) }
}

private fun pending(clickMan: ClickMan): JsonObject = buildJsonObject {
    put("ok", true)
    put("pending", clickMan.pendingEvents)
}

private fun reply(answer: JsonObject) {
    println(answer)
    System.out.flush()
}
