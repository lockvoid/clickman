package com.lockvoid.clickman.android

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.lockvoid.clickman.ClickMan

/**
 * The process lifecycle as events: `app_backgrounded` when the app leaves the
 * foreground, `app_opened` when it comes back. The first start is the launch,
 * which `ClickMan.appLaunched` has already reported.
 */
internal class LifecycleTracking(
    private val clickMan: ClickMan,
    private val tracksLifecycle: Boolean,
    private val context: () -> Map<String, Any?>,
) : DefaultLifecycleObserver {
    private var backgrounded = false

    override fun onStart(owner: LifecycleOwner) {
        if (!backgrounded) {
            return
        }

        backgrounded = false
        clickMan.setContext(context())
        if (tracksLifecycle) {
            clickMan.track("app_opened", mapOf("from_background" to true))
        }
    }

    override fun onStop(owner: LifecycleOwner) {
        backgrounded = true
        if (tracksLifecycle) {
            clickMan.track("app_backgrounded")
        }
        clickMan.flushInBackground()
    }
}
