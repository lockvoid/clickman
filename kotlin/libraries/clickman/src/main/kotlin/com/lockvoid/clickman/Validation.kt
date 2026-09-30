package com.lockvoid.clickman

/** The event names and external ids a client stores, counted in code points (events.json). */
internal object Validation {
    const val EVENT_RULE = "an event name is 1 to 200 characters without control characters"
    const val EXTERNAL_ID_RULE = "an external id is 1 to 256 characters without control characters"

    fun isEvent(name: String): Boolean = fits(name, 200)

    fun isExternalId(id: String): Boolean = fits(id, 256)

    private fun fits(text: String, maxCodePoints: Int): Boolean =
        text.codePointCount(0, text.length) in 1..maxCodePoints && text.codePoints().noneMatch(::isControl)

    private fun isControl(codePoint: Int): Boolean = Character.getType(codePoint) == Character.CONTROL.toInt()
}
