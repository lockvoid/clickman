package com.lockvoid.clickman

import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days

/**
 * Sends the queue one batch at a time. A batch is due at [flushAt] waiting
 * events, at an oldest event of [flushInterval] or when forced; after a
 * failure nothing is sent until its backoff has passed. Failures are counted
 * in memory. Runs on the client's single worker thread only.
 */
internal class Delivery(
    private val queue: Queue,
    private val sender: Sender,
    private val flushAt: Int,
    private val flushInterval: Duration,
    private val clock: () -> Long,
    private val random: Random,
) {
    private sealed interface Failures {
        data object None : Failures

        class Consecutive(val count: Int, val nextAttemptAt: Long) : Failures
    }

    private var failures: Failures = Failures.None

    /** Sends batches until nothing is due or a send fails. */
    fun drain(force: Boolean) {
        while (true) {
            if (!sendNextBatch(force)) return
        }
    }

    /** True when a batch left the queue. */
    private fun sendNextBatch(force: Boolean): Boolean {
        val now = clock()
        if (backingOff(now)) return false
        val events = take(now, force)
        return events.isNotEmpty() && send(events, now)
    }

    private fun backingOff(now: Long): Boolean = when (val current = failures) {
        Failures.None -> false
        is Failures.Consecutive -> now < current.nextAttemptAt
    }

    private fun take(now: Long, force: Boolean): List<QueuedEvent> = queue.transaction { tx ->
        tx.purge(trackedBefore = now - MAX_AGE.inWholeMilliseconds)
        if (force || due(tx.backlog(), now)) tx.oldest(Batch.MAX_EVENTS) else emptyList()
    }

    private fun due(backlog: Backlog?, now: Long): Boolean =
        backlog != null && (backlog.count >= flushAt || now - backlog.oldest >= flushInterval.inWholeMilliseconds)

    private fun send(events: List<QueuedEvent>, now: Long): Boolean {
        val batch = events.take(Batch.cut(events.map { it.body }, Batch.MAX_EVENTS, Batch.MAX_BYTES))
        val response = sender.post(Batch.encode(sentAt = now, batch.map { it.body }))
        return when (Outcome.of(response.status)) {
            Outcome.DELIVERED -> settle(batch)
            Outcome.REFUSED -> settle(batch).also {
                logger.warning("ClickMan dropped ${batch.size} events the server refused: ${response.detail}")
            }
            Outcome.RETRY -> retry(batch, response)
        }
    }

    private fun settle(batch: List<QueuedEvent>): Boolean {
        queue.transaction { it.deleteThrough(batch.last().seq) }
        failures = Failures.None
        return true
    }

    private fun retry(batch: List<QueuedEvent>, response: Response): Boolean {
        val count = consecutiveFailures() + 1
        val delay = Backoff.delay(count, response.retryAfter, random)
        failures = Failures.Consecutive(count, clock() + delay.inWholeMilliseconds)
        logger.warning("ClickMan retries ${batch.size} events in $delay: ${response.detail}")
        return false
    }

    private fun consecutiveFailures(): Int = when (val current = failures) {
        Failures.None -> 0
        is Failures.Consecutive -> current.count
    }

    private companion object {
        val MAX_AGE = 30.days
    }
}
