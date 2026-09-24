plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.lockvoid.clickman.android"
    compileSdk = 36

    defaultConfig {
        minSdk = 28
        ndk { abiFilters += listOf("arm64-v8a") }
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs { useLegacyPackaging = false }
    }

    testOptions {
        unitTests.all {
            it.systemProperty("jna.library.path", project(":clickman").layout.projectDirectory.dir("build/host").asFile.absolutePath)
        }
    }
}

dependencies {
    api(project(":clickman"))
    implementation("${libs.jna.get()}@aar")
    implementation(libs.androidx.lifecycle.process)
    testImplementation(testFixtures(project(":clickman")))
    testImplementation(libs.jna)
    testImplementation(libs.kotlin.test.junit)
}
