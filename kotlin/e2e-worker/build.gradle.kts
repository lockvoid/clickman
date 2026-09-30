plugins {
    id("clickman.kotlin-jvm")
    application
}

dependencies {
    implementation(project(":clickman"))
    implementation(libs.androidx.sqlite.bundled)
    implementation(libs.kotlinx.serialization.json)
}

application {
    mainClass.set("com.lockvoid.clickman.e2e.WorkerKt")
}
