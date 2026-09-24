package com.lockvoid.clickman

import java.io.Closeable
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.logging.Level
import java.util.logging.Logger
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

class ClickManException(message: String) : Exception(message)

/**
 * ClickMan analytics for the JVM and Android. Events are queued on the device
 * the moment they are tracked and sent in gzipped batches — when enough are
 * waiting, when the oldest has waited long enough and whenever [flush] asks.
 * Tracking never blocks on the network and never throws.
 */
class ClickMan(configuration: Configuration) : Closeable {
    class Configuration(
        /** The ingest server, e.g. `https://clickman.example.com`. */
        val endpoint: String,
        /** The write key of this app's source. */
        val writeKey: String,
        /** The queue's SQLite file; keep it out of backups. */
        val storage: File,
    ) {
        /** A batch is sent once this many events are waiting. */
        var flushAt: Int = 20

        /** A batch is sent once the oldest waiting event is this old. */
        var flushInterval: Duration = 30.seconds

        /** The most events kept on the device; the oldest go first. */
        var maxQueue: Int = 10_000

        /** The context stamped on every event: app, device, os, locale, timezone. */
        var context: Map<String, Any?> = emptyMap()

        internal var pollInterval: Duration = 5.seconds
    }

    private val logger = Logger.getLogger("ClickMan")
    private val queue = Queue(
        configuration.storage,
        mapOf(
            "flushAt" to configuration.flushAt,
            "flushIntervalMs" to configuration.flushInterval.inWholeMilliseconds,
            "maxQueue" to configuration.maxQueue,
        ).toJson(),
        logger,
    )
    private val sender = Sender(queue, configuration.endpoint, configuration.writeKey, logger)
    private val worker = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "clickman").apply { isDaemon = true }
    }

    init {
        setContext(configuration.context)
        val interval = configuration.pollInterval.inWholeMilliseconds
        worker.scheduleWithFixedDelay({ drain(force = false) }, interval, interval, TimeUnit.MILLISECONDS)
    }

    /** Queues an event. Properties are JSON values; dates are sent as ISO 8601 strings. */
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        queue.track(event, properties.toJson(), System.currentTimeMillis())
    }

    /** Makes the host's user id the actor of every event tracked from now on. */
    fun identify(externalId: String) {
        queue.identify(externalId)
    }

    /**
     * Merges traits of the actor into `context.traits` of every event tracked
     * from now on, e.g. `mapOf("plan" to "pro")`; null removes a trait. The
     * traits are kept across launches until [reset].
     */
    fun setTraits(traits: Map<String, Any?>) {
        queue.setTraits(traits.toJson())
    }

    /** Makes events tracked from now on anonymous and forgets the traits, e.g. after signing out. */
    fun reset() {
        queue.reset()
    }

    /** Replaces the context stamped on events tracked from now on. */
    fun setContext(context: Map<String, Any?>) {
        queue.setContext((context + LIBRARY).toJson())
    }

    /**
     * Records a launch of the app: `app_installed` on the first launch,
     * `app_updated` on the first launch of a new version or build, then
     * `app_opened`.
     */
    fun appLaunched(version: String, build: String) {
        queue.appLaunched(version, build, System.currentTimeMillis())
    }

    /** Sends everything waiting and returns once the queue is empty or a send failed and waits for its retry. */
    fun flush() {
        try {
            worker.submit { drain(force = true) }.get()
        } catch (error: RejectedExecutionException) {
            logger.warning("ClickMan could not flush: it is closed")
        }
    }

    /** Starts sending everything waiting without waiting for it. */
    fun flushInBackground() {
        try {
            worker.execute { drain(force = true) }
        } catch (error: RejectedExecutionException) {
            logger.warning("ClickMan could not flush: it is closed")
        }
    }

    /** Events on the device, in flight or waiting. */
    val pendingEvents: Int
        get() = queue.pending

    override fun close() {
        worker.shutdown()
        worker.awaitTermination(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        queue.close()
    }

    private fun drain(force: Boolean) {
        try {
            sender.drain(force)
        } catch (error: RuntimeException) {
            logger.log(Level.WARNING, "ClickMan could not send its queue", error)
        }
    }

    companion object {
        const val VERSION = "0.1.0"

        private const val CLOSE_TIMEOUT_SECONDS = 5L
        private val LIBRARY = mapOf("library" to mapOf("name" to "clickman-kotlin", "version" to VERSION))
    }
}
