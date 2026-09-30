# The shared contract

`queue.sql` is the device queue of every client, format 1, and
`queue-upgrade.sql` adopts a store the 0.1 Rust core wrote.
`ruby tools/queue_schema.rb` embeds both in the Swift, Kotlin and Rust clients;
`--check` fails when a copy differs. Edit them here, never in a copy.

The fixtures are the rules of `docs/PROTOCOL.md` as data. Every implementation
runs the ones that apply to it and fails on a case it does not pass:

| Fixture | Rule | Run by |
|---|---|---|
| `flatten.json` | flattening of properties and context | Rails engine, ingest server |
| `sanitize.json` | the sanitizer and its default fragments | Rails engine, ingest server |
| `events.json` | event names and external ids a client stores | Swift, Kotlin, Rust clients |
| `traits.json` | how traits merge | Swift, Kotlin, Rust clients |
| `lifecycle.json` | the events a launch records | Swift, Kotlin, Rust clients |
| `batches.json` | which waiting events a batch takes | Swift, Kotlin, Rust clients |
| `outcomes.json` | what a response does to the batch | Swift, Kotlin, Rust clients |
| `backoff.json` | the delay before the next attempt | Swift, Kotlin, Rust clients |

Tests read the fixtures from this directory; no package copies them.
