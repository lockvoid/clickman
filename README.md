# ClickMan

Product analytics for Rails at the price of a small database.

ClickMan keeps your product events in your own database — PostgreSQL, or
SQLite for an app that runs on one server — column-wise and compressed, and
answers the questions a product team asks every day — daily, weekly and monthly
actives, D1/D7/D30 retention, funnels, which events happen and how often — from
summaries computed in the background. Events can also be forwarded to Mixpanel
or anywhere else.

```
 iOS / Android / Rust app                     Rails app
┌──────────────────────┐   POST /v1/batch   ┌──────────────────┐      ┌─────────────────────────┐
│ track → device queue │ ─────────────────► │ clickman-ingest  │ ───► │ clickman_events (raw)    │
│ (SQLite, gzip batches│   write key, gzip  │ (Rust, Axum)     │      │   │ ClickMan::RotationJob │
│  retries, offline)   │                    │ sanitize, dedup  │      │   ▼                      │
└──────────────────────┘                    └──────────────────┘      │ chunks · counts · bits  │
                                                                      │   ▼                      │
                        ClickMan.track (server-side events) ────────► │ reports → /analytics     │
                                                                      │ ClickMan::DeliveryJob ──► Mixpanel
                                                                      └─────────────────────────┘
```

- `docs/PROTOCOL.md` — the wire format every client speaks (Segment's shape, with `externalId`).
- `docs/STORAGE.md` — the tables, the chunk format, rotation, retention and erasure.
- `docs/FUNNELS.md` — the funnel files.
- `docs/INSTALLATION.md` — the Rails engine, the Swift package, the Kotlin build and the Rust crate in a host.

## Rails

### Install

```ruby
gem 'clickman'
```

```sh
bin/rails generate clickman:install --database analytics      # or without --database for the primary one
bin/rails click_man:install:migrations DATABASE=analytics     # or without DATABASE for the primary one
bin/rails db:migrate
```

The generator writes `config/initializers/clickman.rb` and
`config/clickman/funnels/`; the engine's migration builds the tables on
PostgreSQL or SQLite. On PostgreSQL keep the database dump in SQL
(`schema_format = :sql`): `schema.rb` drops the chunk table's
`SET STORAGE EXTERNAL`.

### Configure

```ruby
ClickMan.configure do |config|
  config.database = :analytics
  config.write_keys = { ios: ENV['CLICKMAN_IOS_WRITE_KEY'], android: ENV['CLICKMAN_ANDROID_WRITE_KEY'] }
  config.filter_fragments += %w[price amount]
  config.base_controller_class = 'Admin::BaseController'
end
```

| Setting | Default | |
|---|---|---|
| `database` | the primary one | the `database.yml` name ClickMan's tables live in |
| `write_keys` | `{}` | source name → write key; blank keys are skipped |
| `filter_fragments` | passwords, emails, tokens, keys, phones, addresses, names, birth dates… | a key containing one of them is stored as `[FILTERED]`; emails, card numbers and phone numbers are filtered in any value |
| `max_event_age` | 90 days | older events are refused at ingest |
| `rate_limit` | 20/s, burst 100 | per write key and client address |
| `dedup_window` | 7 days | raw events are kept this long for deduplication |
| `retention` | forever | whole months of chunks older than this are dropped |
| `rotation_lag` | 2 minutes | rotation and delivery leave younger events to ingest transactions in flight |
| `funnels_path` | `config/clickman/funnels` | |
| `base_controller_class` | none | the controller the dashboard inherits from; the dashboard refuses to open without it |
| `destinations` | `[]` | where events are forwarded |
| `ingest_url` | `http://127.0.0.1:4130` | where the development ingest server listens |
| `publish_on_boot` | `true` | publish the ingest settings when the app boots (`bin/rails clickman:publish` otherwise) |

The ingest server reads the write key digests, the filter and the limits from
the database, where the engine publishes them — the rules are written once, in
Ruby.

### The dashboard

```ruby
mount ClickMan::Engine, at: '/analytics'
```

It inherits `base_controller_class`, so your admin authentication guards it.

### Jobs

`ClickMan::RotationJob` rotates new events into chunks, prunes and refreshes the
reports; run it every hour or more often. `ClickMan::DeliveryJob` forwards new
events to the destinations. With Solid Queue:

```yaml
clickman_rotation:
  class: ClickMan::RotationJob
  schedule: every hour
clickman_delivery:
  class: ClickMan::DeliveryJob
  schedule: every 5 minutes
```

`bin/rails clickman:rotate` and `bin/rails clickman:deliver` do the same by hand.

### Events from Rails

```ruby
ClickMan.track('subscription_started', external_id: user.id, properties: { product_id: 'pro_yearly' })
```

The event is filtered like any other and never raises: a failure is reported to
`Rails.error` and `track` returns `false`. A `message_id:` (a UUID) makes it
idempotent — the same id is stored once.

### Destinations

```ruby
config.destinations = [
  ClickMan::Destinations::Mixpanel.new(project_id: '123', username: ENV['MIXPANEL_USER'], secret: ENV['MIXPANEL_SECRET'], region: :eu)
]
```

A destination is a `ClickMan::Destination` with `deliver(events)`: it receives
pages of events in the order they arrived and raises to have the page sent
again; each destination keeps its own place. Raw events stay until every
destination has received them.

### Erasure

```ruby
ClickMan.erase!(user.id)
```

removes the actor's raw events, rewrites the chunks that hold them and clears
their activity. Events already forwarded to a destination are that
destination's to erase.

## The ingest server

`clickman-ingest` is a small Rust server that authenticates, rate-limits,
filters and stores batches; everything else happens in Rails.

- **Development:** `plugin :clickman` in `config/puma.rb` runs it beside Puma,
  on `config.ingest_url`, against ClickMan's database.
- **Production:** run `bundle exec clickman-ingest` as its own service.

| Environment | |
|---|---|
| `DATABASE_URL` | ClickMan's database: `postgres://…`, or `sqlite:///path/to/analytics.sqlite3` |
| `CLICKMAN_INGEST_BIND` | `host:port`, default `127.0.0.1:4130` |
| `CLICKMAN_INGEST_DATABASE_POOL` | connections, default 4 |
| `CLICKMAN_INGEST_SETTINGS_REFRESH` | seconds between reads of the published settings, default 30 |
| `CLICKMAN_INGEST_BINARY` | a prebuilt binary; without it `clickman-ingest` builds one with Cargo |

## Apps

Each client is a native implementation of the client rules in
`docs/PROTOCOL.md`: a SQLite queue in the format of `protocol/queue.sql` that
batches, retries with backoff and survives restarts, and the lifecycle events
`app_installed`, `app_updated`, `app_opened` and `app_backgrounded`. The shared
fixtures in `protocol/fixtures` run in every client's tests.

### Swift

```swift
let analytics = try ClickMan(configuration: .init(endpoint: URL(string: "https://clickman.example.com")!, writeKey: "…"))
analytics.identify("42")
analytics.setTraits(["plan": "pro"])
analytics.track("export_completed", properties: ["format": "mp4"])
```

The package is the repository root and brings GRDB 7; the SDK sends what is
waiting when the app leaves the foreground or the network returns.

### Kotlin

```kotlin
val analytics = ClickManAndroid.start(context, endpoint = "https://clickman.example.com", writeKey = "…")
analytics.identify("42")
analytics.track("export_completed", mapOf("format" to "mp4"))
```

`kotlin/libraries/clickman` runs on any JVM over the `androidx.sqlite` driver
it is given; `kotlin/libraries/clickman-android` adds the Android context, the
lifecycle events and the OS SQLite.

### Rust

```rust
let analytics = ClickMan::open(Config::new("https://clickman.example.com", "…", queue_path), http)?;
analytics.identify("42")?;
analytics.track("export_completed", json!({ "format": "mp4" }))?;
analytics.send_due().await?; // on the host's own timer, e.g. every 5 seconds
```

`http` is the host's `HttpClient`; the crate links no runtime.

## Development

Every suite runs through [mise](https://mise.jdx.dev); `scripts/gate` runs them
one at a time, one log each under `tmp/gates/`, and reads the verdict from the
logs.

| | |
|---|---|
| `mise run test:contract` | the embedded queue schema copies match `protocol/` |
| `mise run test:rails` / `test:rails-sqlite` | the Rails engine on PostgreSQL / SQLite |
| `mise run test:rust` | the protocol, the ingest server on template databases the migration builds, the Rust client, clippy |
| `mise run test:swift` / `test:swift-ios` | the Swift client on the Mac / on an iOS simulator |
| `mise run test:kotlin` / `test:kotlin-android` | the Kotlin client / its Android half |
| `mise run e2e` | the Swift, Kotlin and Rust workers through the real ingest server into the engine, on both databases |

| Directory | Contents |
|---|---|
| `protocol` | the device queue schema and the shared fixtures |
| `ruby` | the `clickman` Rails engine and its migration |
| `rust` | Cargo workspace: the ingest server, the wire protocol, the Rust client and its E2E worker |
| `swift` | the Swift client, its tests and E2E worker (`Package.swift` is at the root) |
| `kotlin` | Gradle build: the JVM client, its Android half and the E2E worker |
| `tools` | the queue schema embedding and the ingest test templates |
| `docs` | the protocol, the storage, the funnels, installation |

## License

MIT
