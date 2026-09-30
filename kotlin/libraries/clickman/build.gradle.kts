import java.time.Duration

// The client on the JVM; the host hands in its SQLite driver, so no Android import and no bundled SQLite.
plugins {
    id("clickman.kotlin-jvm")
    `java-library`
    `java-test-fixtures`
}

dependencies {
    api(libs.androidx.sqlite)
    implementation(libs.kotlinx.serialization.json)
    testFixturesApi(libs.kotlinx.serialization.json)
    testImplementation(libs.androidx.sqlite.bundled)
    testImplementation(libs.kotlin.test.junit)
}

tasks.test {
    useJUnit()
    val fixtures = rootProject.projectDir.resolve("../protocol/fixtures").canonicalFile
    inputs.dir(fixtures).withPropertyName("fixtures").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("clickman.fixtures", fixtures.absolutePath)
    timeout.set(Duration.ofMinutes(10))
    testLogging { events("failed") }
}
