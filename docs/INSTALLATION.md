# Installation

ClickMan is consumed from its GitHub repository or a checkout beside the
application; registry publication is a separate release step. Every package
lives in its own directory and speaks the one contract in `docs/PROTOCOL.md`.

## Rails

```ruby
# Gemfile
gem 'clickman', git: 'https://github.com/lockvoid/clickman.git'
```

```sh
bin/rails generate clickman:install --database analytics
bin/rails click_man:install:migrations DATABASE=analytics
bin/rails db:migrate
```

The engine needs Rails 8, and PostgreSQL or SQLite. The ingest server is built
from `rust/` with Cargo the first time `bundle exec clickman-ingest` runs, or
taken from `CLICKMAN_INGEST_BINARY`; a production image builds it once:

```sh
cargo build --release --locked --manifest-path "$(bundle info clickman --path)/../rust/Cargo.toml" -p clickman-ingest
```

## Swift

The package is the repository root:

```yaml
# XcodeGen
packages:
  ClickMan:
    path: ../clickman
```

```swift
// Package.swift
.package(url: "https://github.com/lockvoid/clickman.git", branch: "main")
```

It needs iOS 16 or macOS 13 and brings GRDB 7, which it shares with any other
GRDB user in the app; SQLite is the system one.

## Kotlin and Android

`kotlin/` is a Gradle build a host includes as a composite; its modules resolve
as `com.lockvoid.clickman:*`:

```kotlin
// settings.gradle.kts
includeBuild("../clickman/kotlin") { name = "clickman" }

// app/build.gradle.kts
dependencies {
    implementation("com.lockvoid.clickman:clickman-android")
}
```

`clickman` is a JVM library over `androidx.sqlite`; `clickman-android` adds the
Android context, the lifecycle events and the OS SQLite driver, so nothing
native is bundled. A JVM host passes its own driver, e.g. `BundledSQLiteDriver`.

## Rust

```toml
[dependencies]
clickman = { git = "https://github.com/lockvoid/clickman.git" }
```

The crate links no runtime: the application provides the HTTP client and calls
`send_due` on its own timer.
