pluginManagement {
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "clickman"

include(":clickman")
include(":e2e-worker")
project(":clickman").projectDir = file("libraries/clickman")

// The AAR needs an Android SDK; JVM-only builds leave it out.
if (providers.gradleProperty("android").orNull == "true" || providers.environmentVariable("ANDROID_HOME").isPresent) {
    include(":clickman-android")
    project(":clickman-android").projectDir = file("libraries/clickman-android")
}
