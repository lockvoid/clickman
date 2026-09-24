plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-test-fixtures`
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly(libs.jna)
    implementation(libs.kotlinx.serialization.json)
    testFixturesApi(libs.kotlinx.serialization.json)
    testFixturesImplementation(libs.jna)
    testImplementation(libs.jna)
    testImplementation(libs.kotlin.test.junit)
}

tasks.test {
    useJUnit()
    val library = layout.projectDirectory.file("build/host/libclickman_core.dylib").asFile
    inputs.files(library).withPropertyName("clickmanHostLibrary")
    systemProperty("jna.library.path", library.parent)
    doFirst {
        require(library.exists()) { "$library is missing — run `kotlin/build.sh host`" }
    }
    testLogging { events("failed") }
}

tasks.register<JavaExec>("e2eClient") {
    description = "Sends a fixed set of events to a running ingest server: -Pendpoint= -PwriteKey= -Pqueue="
    classpath = sourceSets["testFixtures"].runtimeClasspath
    mainClass = "com.lockvoid.clickman.EndToEndClientKt"
    val library = layout.projectDirectory.file("build/host/libclickman_core.dylib").asFile
    systemProperty("jna.library.path", library.parent)
    args(
        providers.gradleProperty("endpoint").get(),
        providers.gradleProperty("writeKey").get(),
        providers.gradleProperty("queue").get(),
    )
}
