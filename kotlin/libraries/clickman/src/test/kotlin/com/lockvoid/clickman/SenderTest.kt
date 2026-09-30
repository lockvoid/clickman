package com.lockvoid.clickman

import java.net.ServerSocket
import java.util.logging.Level
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import org.junit.Rule
import org.junit.rules.Timeout

class SenderTest {
    @get:Rule
    val timeout: Timeout = Timeout.seconds(60)

    private val server = StubServer.start()
    private val body = Batch.encode(TestClock.START, listOf("""{"event":"a"}"""))

    @AfterTest
    fun tearDown() {
        server.stop()
    }

    @Test
    fun aBatchIsPostedGzippedWithTheWriteKey() {
        val response = Sender(server.endpoint, "android-key").post(body)

        val request = server.requests.single()
        assertEquals(202, response.status)
        assertEquals("POST", request.method)
        assertEquals("/v1/batch", request.path)
        assertEquals("Bearer android-key", request.headers["authorization"])
        assertEquals("application/json", request.headers["content-type"])
        assertEquals("gzip", request.headers["content-encoding"])
        assertContentEquals(body, request.body)
    }

    @Test
    fun anEndpointEndingInASlashStillPostsToTheBatchPath() {
        Sender("${server.endpoint}/", "key").post(body)

        assertEquals("/v1/batch", server.requests.single().path)
    }

    @Test
    fun theRetryAfterIsReadInSeconds() {
        server.status = 429
        server.retryAfter = "120"

        assertEquals(120.seconds, Sender(server.endpoint, "key").post(body).retryAfter)
    }

    @Test
    fun aRetryAfterThatIsNoNumberOfSecondsIsIgnoredWithAWarning() {
        server.status = 503
        server.retryAfter = "Wed, 30 Sep 2026 12:00:00 GMT"

        lateinit var response: Response
        val records = logged { response = Sender(server.endpoint, "key").post(body) }

        assertNull(response.retryAfter)
        assertEquals(Level.WARNING, records.single().level)
    }

    @Test
    fun theDetailCarriesTheStatusAndTheServersAnswer() {
        server.status = 401
        server.answer = """{"error":"invalid_write_key"}"""

        val response = Sender(server.endpoint, "key").post(body)

        assertEquals(401, response.status)
        assertEquals("""HTTP 401 {"error":"invalid_write_key"}""", response.detail)
    }

    @Test
    fun aRedirectIsAnAnswerAndIsNotFollowed() {
        server.status = 301
        server.location = "${server.endpoint}/elsewhere"

        val response = Sender(server.endpoint, "key").post(body)

        assertEquals(301, response.status)
        assertEquals(listOf("/v1/batch"), server.requests.map { it.path })
    }

    @Test
    fun anEndpointThatIsNoHttpUrlIsRefused() {
        assertFailsWith<IllegalArgumentException> { Sender("ftp://clickman.example.com", "key") }
    }

    @Test
    fun noAnswerIsStatusZero() {
        val port = ServerSocket(0).use { it.localPort }

        val response = Sender("http://127.0.0.1:$port", "key").post(body)

        assertEquals(0, response.status)
        assertTrue(response.detail.startsWith("no answer from http://127.0.0.1:$port/v1/batch"), response.detail)
    }
}
