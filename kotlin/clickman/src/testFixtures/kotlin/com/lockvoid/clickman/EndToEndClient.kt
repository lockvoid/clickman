package com.lockvoid.clickman

import java.io.File
import kotlin.system.exitProcess

fun main(arguments: Array<String>) {
    val (endpoint, writeKey, queue) = arguments
    ClickMan(ClickMan.Configuration(endpoint, writeKey, File(queue))).use { analytics ->
        analytics.appLaunched("1.0", "1")
        analytics.identify("e2e-kotlin")
        analytics.setTraits(mapOf("plan" to "pro"))
        analytics.track("export_completed", mapOf("format" to "mp4", "contact" to mapOf("email" to "someone@example.com")))
        analytics.flush()

        if (analytics.pendingEvents != 0) {
            System.err.println("${analytics.pendingEvents} events were not accepted")
            exitProcess(1)
        }
    }
}
