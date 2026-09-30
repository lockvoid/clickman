package com.lockvoid.clickman.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import androidx.annotation.MainThread
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.sqlite.driver.AndroidSQLiteDriver
import com.lockvoid.clickman.ClickMan
import java.io.File

object ClickManAndroid {
    /**
     * Starts ClickMan for this app: the queue in no-backup storage, the
     * standard context, the lifecycle events and a send whenever the network
     * returns. Call once, from the main thread, e.g. in `Application.onCreate`.
     */
    @MainThread
    fun start(
        context: Context,
        endpoint: String,
        writeKey: String,
        tracksLifecycle: Boolean = true,
        configure: ClickMan.Configuration.() -> Unit = {},
    ): ClickMan {
        val application = context.applicationContext
        val clickMan = ClickMan(configuration(application, endpoint, writeKey).apply(configure))
        if (tracksLifecycle) {
            val (version, build) = AndroidContext.version(application)
            clickMan.appLaunched(version, build)
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(LifecycleTracking(clickMan, tracksLifecycle) { AndroidContext.of(application) })
        flushWhenTheNetworkReturns(application, clickMan)
        return clickMan
    }

    private fun configuration(application: Context, endpoint: String, writeKey: String): ClickMan.Configuration {
        val storage = File(application.noBackupFilesDir, "clickman/queue.sqlite")
        return ClickMan.Configuration(endpoint, writeKey, storage, AndroidSQLiteDriver()).apply {
            context = AndroidContext.of(application)
        }
    }

    private fun flushWhenTheNetworkReturns(application: Context, clickMan: ClickMan) {
        application.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    clickMan.flushInBackground()
                }
            },
        )
    }
}
