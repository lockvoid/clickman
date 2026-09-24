# Storage

ClickMan is built to run on the smallest database a hosting provider sells. Every
design choice below serves that: raw rows live only as long as deduplication
needs them, everything else is stored column-wise and compressed, and reports
read small summaries computed in the background.

The stores are PostgreSQL and SQLite. The layout is the contract every store
adapter implements; table names carry the `clickman_` prefix.

## Flow

```
ingest ──► clickman_events (raw, row-wise, dedup window)
             │  every rotation (hourly by default)
             ▼
           clickman_chunks (column-wise, compressed, kept for `retention`)
             │
             ├──► clickman_daily_counts   events and actors per event per day
             ├──► clickman_actor_days     one bit per actor per active day
             └──► clickman_reports        funnels, retention, actives (cached)
```

Nothing is lost on the way: a chunk keeps every event's time, actor, name,
properties and context. Only `messageId` and the receive time are dropped, once
the deduplication window has passed.

## Raw events — `clickman_events`

| Column | Type | |
|---|---|---|
| `message_id` | `uuid` | primary key — the deduplication key |
| `occurred_at` | `timestamptz` | corrected event time |
| `received_at` | `timestamptz` | server time of arrival; the rotation cursor |
| `external_id` | `text` | |
| `event` | `text` | |
| `properties` | `jsonb` | flattened and sanitized |
| `context` | `jsonb` | flattened and sanitized |

Writers insert with `ON CONFLICT (message_id) DO NOTHING`. Rows are deleted once
they are rotated and older than `dedup_window` (default 7 days).

## Dictionaries

| Table | Holds |
|---|---|
| `clickman_event_names` (`id int4`, `name text` unique) | event names |
| `clickman_keys` (`id int4`, `key text` unique) | property and context keys; context keys are stored as `context.<key>` |
| `clickman_actors` (`id int4`, `external_id text` unique, `first_seen_on date`, `erased_at timestamptz`) | actors; an erased actor keeps its row with no `external_id` |

Dictionaries fill themselves: a name, key or actor is added the first time a
rotation meets it. There is no event catalog.

## Chunks — `clickman_chunks`

The rotated matrix. A chunk holds up to 4,096 events of one name from one day:

| Column | Type | |
|---|---|---|
| `day` | `date` | partition key, monthly partitions |
| `event_name_id` | `int4` | |
| `seq` | `int4` | chunk number within `(day, event_name_id)` |
| `events` | `int4` | number of events in the chunk |
| `key_ids` | `int4[]` | keys present in the chunk, for pruning |
| `payload` | `bytea` | the columns, MessagePack then Zstandard |

The payload is a MessagePack map:

```
{
  "v": 1,
  "t": [ … ],            milliseconds since the start of `day` (UTC), delta-encoded
  "a": [ … ],            actor ids, one per event
  "c": [                 one entry per key present in the chunk
    [ key_id, [ value, value, nil, … ] ],
    …
  ]
}
```

Events inside a chunk are ordered by time. Column values are MessagePack
scalars — `nil` where the event has no such key, strings inline — so repeated
values cost almost nothing once Zstandard has seen them. A rotation tops up the
last chunk of a day until it holds 4,096 events and then starts the next `seq`,
so a day costs one chunk per 4,096 events however often rotation runs; a full
chunk is never rewritten except to erase an actor.

Days are UTC days.

## Summaries

| Table | Key | Holds |
|---|---|---|
| `clickman_daily_counts` | `(day, event_name_id)` | `events`, `actors` |
| `clickman_actor_days` | `(actor_id, year)` | `days bit varying(366)`, bit *n* set when the actor was active on day *n* of the year |
| `clickman_reports` | `key` | the cached JSON of a report and when it was computed |

Daily, weekly and monthly actives and D1/D7/D30 retention read
`clickman_actor_days` and `clickman_actors.first_seen_on`. Funnels decode only the
chunks of the step events in the requested range.

## Rotation

A rotation takes raw rows with `received_at` past the last cursor and at least
`rotation_lag` (default 2 minutes) old — the time an ingest transaction may still
be in flight — groups them by `(day(occurred_at), event)`, tops up or appends
chunks, sets actor bits, recomputes the daily counts of the days it touched and
advances the cursor, in one transaction per 20,000 events. It is idempotent, one
rotation runs at a time (an advisory lock) and it is safe to run concurrently
with ingest; run it every hour or more often.

## Retention and erasure

`retention` (default: forever) drops whole monthly partitions of chunks, with
the daily counts and actor bits of those months. Raw events are deleted once
rotation and every destination have passed them and `dedup_window` is over; a
destination that keeps failing keeps them.

Erasing an actor deletes its raw rows, rewrites the chunks that contain it,
clears its bits and recounts the days it touched; its dictionary row stays as a
tombstone without the `external_id`. Events for the same `external_id` that
arrive later start a new actor, and events already forwarded to a destination
are that destination's to erase.

## Settings — `clickman_settings`

The Rails engine publishes the settings the ingest server needs — write key
digests, sanitizer fragments, limits — as JSON rows. The ingest server reads
them at start and every 30 seconds, so the rules are written once, in the host
application's configuration.

## SQLite

The SQLite store (`sql/sqlite/v1.sql`) keeps the same tables for an app that runs
on one server, with these differences:

- Chunks are one table; retention deletes their rows by day instead of dropping
  partitions.
- Activity bits are text of 366 `0`/`1` characters, JSON columns are text and
  times are text in the format Rails writes (`2026-09-23 12:00:00.250000`), so
  the ingest server and Rails compare them the same way.
- Writes take the database's write lock (`BEGIN IMMEDIATE`), which also keeps
  rotations from running at the same time.

