package com.lockvoid.clickman

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UUIDv7Test {
    private val millis = 0x0192_6A2E_7B1CL

    @Test
    fun theMillisecondsLeadAndTheVersionAndVariantFollow() {
        val id = UUIDv7.generate(millis, Random(7))

        assertEquals(millis, id.mostSignificantBits ushr 16)
        assertEquals(7, id.version())
        assertEquals(2, id.variant())
        assertTrue(Regex("01926a2e-7b1c-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}").matches(id.toString()), id.toString())
    }

    @Test
    fun everythingElseIsRandom() {
        assertEquals("01926a2e-7b1c-7000-8000-000000000000", UUIDv7.generate(millis, EdgeRandom(high = false)).toString())
        val high = UUIDv7.generate(millis, EdgeRandom(high = true))
        assertEquals(7, high.version())
        assertEquals(2, high.variant())
        assertEquals(millis, high.mostSignificantBits ushr 16)
    }

    @Test
    fun idsOfOneMillisecondDiffer() {
        val random = Random(42)
        val ids = List(10_000) { UUIDv7.generate(millis, random) }

        assertEquals(ids.size, ids.toSet().size)
    }
}
