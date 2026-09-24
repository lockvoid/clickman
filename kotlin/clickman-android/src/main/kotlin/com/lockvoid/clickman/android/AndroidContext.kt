package com.lockvoid.clickman.android

import android.content.Context
import android.os.Build
import java.util.Locale
import java.util.TimeZone

/** The standard context of docs/PROTOCOL.md for an Android app. */
internal object AndroidContext {
    fun of(context: Context): Map<String, Any?> {
        val (version, build) = version(context)
        return mapOf(
            "app" to mapOf(
                "name" to context.applicationInfo.loadLabel(context.packageManager).toString(),
                "version" to version,
                "build" to build,
                "namespace" to context.packageName,
            ),
            "device" to mapOf("manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL, "type" to "android"),
            "os" to mapOf("name" to "Android", "version" to Build.VERSION.RELEASE),
            "locale" to Locale.getDefault().toLanguageTag(),
            "timezone" to TimeZone.getDefault().id,
        )
    }

    fun version(context: Context): Pair<String, String> {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return (info.versionName ?: "unknown") to info.longVersionCode.toString()
    }
}
