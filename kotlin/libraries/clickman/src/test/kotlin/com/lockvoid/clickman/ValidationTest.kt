package com.lockvoid.clickman

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ValidationTest {
    @Test
    fun anEventNameIsOneTo200CodePoints() {
        assertTrue(Validation.isEvent("a"))
        assertTrue(Validation.isEvent("a".repeat(200)))
        assertFalse(Validation.isEvent(""))
        assertFalse(Validation.isEvent("a".repeat(201)))
    }

    @Test
    fun aCodePointOutsideTheBasicPlaneCountsOnce() {
        assertTrue(Validation.isEvent("👍".repeat(200)))
        assertFalse(Validation.isEvent("👍".repeat(201)))
    }

    @Test
    fun controlCharactersAreRefusedAndFormatCharactersAreNot() {
        for (control in listOf("\u0000", "\t", "\n", "\u001f", "\u007f", "\u0085", "\u009f")) {
            assertFalse(Validation.isEvent("export${control}completed"), "U+%04X".format(control.single().code))
        }
        assertTrue(Validation.isEvent("export​completed"))
    }

    @Test
    fun anExternalIdIsOneTo256CodePointsWithoutControlCharacters() {
        assertTrue(Validation.isExternalId("*"))
        assertTrue(Validation.isExternalId("x".repeat(256)))
        assertFalse(Validation.isExternalId(""))
        assertFalse(Validation.isExternalId("x".repeat(257)))
        assertFalse(Validation.isExternalId("4\n2"))
    }
}
