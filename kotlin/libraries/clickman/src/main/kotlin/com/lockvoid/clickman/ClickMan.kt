package com.lockvoid.clickman

import androidx.sqlite.SQLiteDriver
import java.io.Closeable
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.logging.Level
import java.util.logging.Logger
import kotlin.random.Random
import kotlin.random.asKotlinRandom
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.json.JsonPrimitive

/** A store ClickMan refuses to open, such as one written by a newer ClickMan. */
class ClickManException(message: String) : Exception(message)

internal val logger: Logger = Logger.getLogger("ClickMan")

/**
 * ClickMan analytics for the JVM and Android. Events are queued on the device
 * the moment they are tracked and sent in gzipped batches — when enough are
 * waiting, when the oldest has waited long enough and whenever [flush] asks.
 * Tracking never blocks on the network and never throws; a failure is logged.
 */
class ClickMan internal constructor(
    configuration: Configuration,
    clock: () -> Long,
    random: Random,
    pollInterval: Duration,
) : Closeable {
    class Configuration(
        /** The ingest server, e.g. `https://clickman.example.com`. */
        val endpoint: String,
        /** The write key of this app's source. */
        val writeKey: String,
        /** The queue's SQLite file; keep it out of backups. */
        val storage: File,
        /** Opens the queue: `AndroidSQLiteDriver` on Android, `BundledSQLiteDriver` on the JVM. */
        val driver: SQLiteDriver,
    ) {
        /** A batch is sent once this many events are waiting. */
        var flushAt: Int = 20

        /** A batch is sent once the oldest waiting event is this old. */
        var flushInterval: Duration = 30.seconds

        /** The most events kept on the device; the oldest go first. */
        var maxQueue: Int = 10_000

        /** The context stamped on every event: app, device, os, locale, timezone. */
        var context: Map<String, Any?> = emptyMap()
    }

    /**
     * Opens the queue at [Configuration.storage]. Throws [IllegalArgumentException] for a
     * configuration that cannot work, [ClickManException] for a store of a newer ClickMan
     * and the driver's error for a store that cannot be opened.
     */
    constructor(configuration: Configuration) :
        this(configuration, System::currentTimeMillis, SecureRandom().asKotlinRandom(), 5.seconds)

    init {
        require(configuration.flushAt > 0 && configuration.maxQueue > 0 && configuration.flushInterval.isPositive()) {
            "flushAt, maxQueue and flushInterval must be positive"
        }
    }

    private val sender = Sender(configuration.endpoint, configuration.writeKey)
    private val queue = Queue.open(configuration.storage, configuration.driver)
    private val tracker = Tracker(queue, configuration.maxQueue, clock, random)
    private val delivery = Delivery(queue, sender, configuration.flushAt, configuration.flushInterval, clock, random)
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "clickman").apply { isDaemon = true } }

    init {
        setContext(configuration.context)
        val interval = pollInterval.inWholeMilliseconds
        worker.scheduleWithFixedDelay({ send(force = false) }, interval, interval, TimeUnit.MILLISECONDS)
    }

    /** Queues an event. Properties are JSON values; dates are sent as ISO 8601 strings. */
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        attempt("track ${JsonPrimitive(event)}") { tracker.track(event, properties.toJsonObject()) }
    }

    /** Makes the host's user id the actor of every event tracked from now on. */
    fun identify(externalId: String) {
        attempt("identify ${JsonPrimitive(externalId)}") { tracker.identify(externalId) }
    }

    /**
     * Merges traits of the actor into `context.traits` of every event tracked
     * from now on, e.g. `mapOf("plan" to "pro")`; null removes a trait. The
     * traits are kept across launches until [reset].
     */
    fun setTraits(traits: Map<String, Any?>) {
        attempt("set the traits") { tracker.setTraits(traits.toJsonObject()) }
    }

    /** Makes events tracked from now on anonymous and forgets the traits, e.g. after signing out. */
    fun reset() {
        attempt("reset") { tracker.reset() }
    }

    /** Replaces the context stamped on events tracked from now on. It is kept in memory only. */
    fun setContext(context: Map<String, Any?>) {
        attempt("set the context") { tracker.setContext(context.toJsonObject()) }
    }

    /**
     * Records a launch of the app: `app_installed` on the first launch,
     * `app_updated` on the first launch of a new version or build, then
     * `app_opened`.
     */
    fun appLaunched(version: String, build: String) {
        attempt("record the launch") { tracker.launch(Release(version, build)) }
    }

    /** Sends everything waiting and returns once the queue is empty or a send failed and waits for its retry. */
    fun flush() {
        try {
            worker.submit { send(force = true) }.get()
        } catch (error: RejectedExecutionException) {
            logger.warning("ClickMan could not flush: it is closed")
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            logger.warning("ClickMan stopped waiting for its flush: the thread was interrupted")
        }
    }

    /** Starts sending everything waiting without waiting for it. */
    fun flushInBackground() {
        try {
            worker.execute { send(force = true) }
        } catch (error: RejectedExecutionException) {
            logger.warning("ClickMan could not flush: it is closed")
        }
    }

    /** Events on the device, waiting or in flight; 0, with the failure logged, when they cannot be counted. */
    val pendingEvents: Int
        get() = try {
            queue.transaction { it.count() }
        } catch (error: Exception) {
            report("count its events", error)
            0
        }

    /** Waits for a send in flight, then releases the queue; calls after this are logged and do nothing. */
    override fun close() {
        worker.shutdown()
        awaitSend()
        queue.close()
    }

    private fun send(force: Boolean) {
        try {
            delivery.drain(force)
        } catch (error: Exception) {
            logger.log(Level.WARNING, "ClickMan could not send its queue", error)
        }
    }

    private fun awaitSend() {
        try {
            if (!worker.awaitTermination(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                logger.warning("ClickMan closed during a send; its events stay queued")
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            logger.warning("ClickMan closed without waiting for its send: the thread was interrupted")
        }
    }

    private inline fun attempt(action: String, work: () -> Unit) {
        try {
            work()
        } catch (error: Exception) {
            report(action, error)
        }
    }

    private fun report(action: String, error: Exception) {
        when (error) {
            is ClickManException -> logger.severe("ClickMan could not $action: ${error.message}")
            else -> logger.log(Level.SEVERE, "ClickMan could not $action", error)
        }
    }

    companion object {
        const val VERSION = "0.1.0"

        private const val CLOSE_TIMEOUT_SECONDS = 5L
    }
}
