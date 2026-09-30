package com.lockvoid.clickman

import kotlin.test.Test
import kotlin.test.assertEquals

class OutcomeTest {
    @Test
    fun anySuccessIsDelivered() {
        for (status in listOf(200, 202, 204, 299)) assertEquals(Outcome.DELIVERED, Outcome.of(status), "$status")
    }

    @Test
    fun aMalformedTooLargeOrUnsupportedBatchIsRefused() {
        for (status in listOf(400, 413, 415)) assertEquals(Outcome.REFUSED, Outcome.of(status), "$status")
    }

    @Test
    fun everyOtherAnswerAndNoAnswerAreRetried() {
        for (status in listOf(0, -1, 100, 301, 302, 401, 403, 404, 408, 422, 429, 500, 502, 503)) {
            assertEquals(Outcome.RETRY, Outcome.of(status), "$status")
        }
    }
}
