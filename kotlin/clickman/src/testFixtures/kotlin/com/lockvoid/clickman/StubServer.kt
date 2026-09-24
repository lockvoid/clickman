package com.lockvoid.clickman

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** A local ingest server that answers with a scripted status and records what was sent. */
class StubServer private constructor(private val server: HttpServer) {
    class Request(val path: String, val headers: Map<String, String>, val body: ByteArray) {
        val batch: JsonObject
            get() = Json.parseToJsonElement(GZIPInputStream(body.inputStream()).readBytes().decodeToString()).jsonObject
    }

    @Volatile var status = 202

    @Volatile var retryAfter: String? = null

    val requests = CopyOnWriteArrayList<Request>()

    val endpoint: String
        get() = "http://127.0.0.1:${server.address.port}"

    val events: List<JsonObject>
        get() = requests.flatMap { request -> request.batch.getValue("batch").jsonArray.map { it.jsonObject } }

    fun stop() {
        server.stop(0)
    }

    companion object {
        fun start(): StubServer {
            val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            val stub = StubServer(server)
            server.createContext("/") { exchange ->
                val headers = exchange.requestHeaders.entries.associate { (name, values) -> name.lowercase() to values.first() }
                stub.requests += Request(exchange.requestURI.path, headers, exchange.requestBody.readBytes())
                stub.retryAfter?.let { exchange.responseHeaders.add("Retry-After", it) }
                val body = """{"accepted":0,"duplicates":0,"rejected":[]}""".toByteArray()
                exchange.sendResponseHeaders(stub.status, body.size.toLong())
                exchange.responseBody.use { it.write(body) }
            }
            server.start()
            return stub
        }
    }
}
