# ClickMan wire protocol, v1

Clients send events in batches over HTTPS. The shape follows the
[Segment Spec](https://segment.com/docs/connections/spec/) — `track`, `messageId`,
`timestamp`, `sentAt`, `context` — with one deliberate difference: the actor is a
single opaque `externalId` supplied by the host application, not a
`userId`/`anonymousId` pair.

The key words MUST, SHOULD and MAY are used as in RFC 2119.

## Endpoint

```
POST /v1/batch
Authorization: Bearer <write key>
Content-Type: application/json
Content-Encoding: gzip            (optional; identity is accepted too)
```

A write key identifies a source (for example `ios` or `android`). Write keys ship
inside applications and are therefore public; they authorize writes only.

## Batch

```json
{
  "sentAt": "2026-09-23T15:04:05.120Z",
  "context": { "library": { "name": "clickman-swift", "version": "0.1.0" } },
  "batch": [
    {
      "type": "track",
      "messageId": "01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f",
      "event": "export_completed",
      "externalId": "user_42",
      "timestamp": "2026-09-23T15:03:59.004Z",
      "properties": { "format": "mp4", "duration": 32.5 },
      "context": { "os": { "name": "iOS", "version": "26.1" } }
    }
  ]
}
```

| Field | Rule |
|---|---|
| `sentAt` | REQUIRED. RFC 3339 time at which the client sent the batch, by the client clock. |
| `batch` | REQUIRED. 1–500 events. |
| `context` | OPTIONAL object. Deep-merged under every event's own `context`; the event wins on conflict. |

Unknown top-level fields are ignored.

## Event

| Field | Rule |
|---|---|
| `type` | REQUIRED. `"track"`. Other values are rejected with `unsupported_type`. |
| `messageId` | REQUIRED. A UUID; clients SHOULD use UUIDv7. The deduplication key. |
| `event` | REQUIRED. 1–200 characters, no control characters. |
| `externalId` | REQUIRED. 1–256 characters. `"*"` is the anonymous actor. |
| `timestamp` | REQUIRED. RFC 3339 time of the event, by the client clock. |
| `properties` | OPTIONAL object. |
| `context` | OPTIONAL object. |

Unknown event fields are ignored.

### Properties and context

Both are JSON objects. The server flattens nested objects into dotted keys
(`{"a": {"b": 1}}` becomes `a.b`). Arrays are kept as JSON text. After
flattening an event MUST NOT carry more than 128 keys in `properties` and 64 in
`context`; keys are 1–128 characters; string values longer than 1,024
characters are truncated to 1,024. Nesting deeper than 5 levels is kept as JSON
text at the fifth level.

Standard context keys, filled by the SDKs:

| Key | Example |
|---|---|
| `app.name`, `app.version`, `app.build`, `app.namespace` | `Example`, `1.40`, `412`, `com.example.app` |
| `device.manufacturer`, `device.model`, `device.type` | `Apple`, `iPhone17,1`, `ios` |
| `os.name`, `os.version` | `iOS`, `26.1` |
| `library.name`, `library.version` | `clickman-swift`, `0.1.0` |
| `locale`, `timezone` | `ru-RU`, `Europe/Moscow` |

## Time

The server corrects the client clock the way Segment does:

```
occurredAt = timestamp + (receivedAt − sentAt)
```

An event whose corrected time lies more than one hour in the future, or further
in the past than the server's `max_event_age` (default 90 days), is rejected
with `timestamp_out_of_range`.

## Sanitizing

Before anything is stored the server removes personal data from `properties` and
`context`:

1. Every key whose last segment contains a filtered fragment (case-insensitive
   substring, as `filter_parameters` in Rails) keeps its key and gets the value
   `"[FILTERED]"`. The default fragments are `passw`, `email`, `secret`,
   `token`, `_key`, `crypt`, `salt`, `certificate`, `otp`, `ssn`, `cvv`, `cvc`,
   `phone`, `address`, `first_name`, `last_name`, `full_name`, `birth`. Hosts
   add their own.
2. Every string value that contains an email address, a payment card number or
   an international phone number becomes `"[FILTERED]"`. Numbers are never
   inspected. A card number is 13–19 digits, optionally grouped by single spaces
   or dashes, starting with 2–6 and passing the Luhn check. A phone number is a
   `+` followed by 10–15 digits, optionally grouped by spaces, dashes, dots or
   parentheses. Card and phone candidates count only when they are not glued to
   a letter or a digit on either side, so identifiers such as UUIDs pass. These
   detectors are a safety net; filtered keys are the rule.

`externalId` is not sanitized: it is the pseudonymous key that only the host
database can resolve to a person. The server stores no IP address.

## Responses

| Status | Body | Client action |
|---|---|---|
| `202` | `{"accepted": n, "duplicates": n, "rejected": [{"index": i, "messageId": "…", "reason": "…"}]}` | Drop the batch. |
| `400` | `{"error": "malformed_batch", "message": "…"}` | Drop the batch. |
| `401` | `{"error": "invalid_write_key"}` | Retry with backoff. |
| `413` | `{"error": "batch_too_large"}` | Drop the batch. |
| `415` | `{"error": "unsupported_encoding"}` | Drop the batch. |
| `429` | `{"error": "rate_limited"}` + `Retry-After` | Retry after the given delay. |
| `5xx` | any | Retry with backoff. |
| any other, or no response | | Retry with backoff. |

Rejection reasons: `unsupported_type`, `invalid_message_id`, `invalid_event`,
`invalid_external_id`, `invalid_timestamp`, `timestamp_out_of_range`,
`invalid_properties`, `invalid_context`, `too_many_keys`.

A batch is limited to 1 MiB on the wire and 4 MiB decompressed.

## Delivery

Delivery is at-least-once. The server deduplicates on `messageId` for as long
as it keeps raw events (the `dedup_window`, default 7 days); a duplicate is
counted in `duplicates` and not stored again.

## Clients

The Swift, Kotlin and Rust clients each implement this section natively. They
embed one store schema, `protocol/queue.sql`, and every client runs the shared
fixtures in `protocol/fixtures` in its tests.

### The queue

A client keeps its events in one SQLite file:

- `events`, one row per tracked event, oldest first: `created_at` is
  milliseconds since the Unix epoch by the device clock and `body` the event
  exactly as it is sent.
- `identity`, one row: the `externalId` of events tracked from now on (`*`,
  the anonymous actor, until the host identifies someone), the traits, and the
  version and build of the last launch.

`PRAGMA user_version` is the store format, 1. A format 0 store is new, or was
written by the 0.1 Rust core; `protocol/queue-upgrade.sql` moves the latter's
`state` table into `identity`. A client refuses a store of a later format.

### Tracking

`track` stamps an event with a new UUIDv7 `messageId`, the current `externalId`,
the device time as `timestamp` and the context: the platform's standard context
(app, device, os, library, locale, timezone) with `traits` added when there are
any. An event whose name or `externalId` breaks the event rules above, counted
in Unicode scalar values, is not stored (`events.json`). The queue keeps at most
10,000 events: the newest event drops the oldest beyond that.

`identify` sets the `externalId` of later events and `reset` makes them
anonymous again and forgets the traits. Traits merge key by key, a null value
removing a trait (`traits.json`).

A launch records `app_installed` when the store remembers no launch,
`app_updated` when the version or the build differs from the last one, then
`app_opened` with `from_background: false` (`lifecycle.json`). Leaving the
foreground records `app_backgrounded` and coming back `app_opened` with
`from_background: true`.

### Sending

A batch is due when 20 events are waiting, when the oldest has waited 30
seconds, when the application leaves the foreground, when the network returns
and when the host flushes. Events older than 30 days are deleted unsent before
a batch is taken.

A batch is the oldest waiting events, at most 100, while their bodies joined by
commas stay within 900,000 bytes (`batches.json`), sent gzipped as
`{"sentAt": …, "batch": [bodies]}`. One batch is in flight at a time. A
delivered or refused batch leaves the queue; after any other answer it stays and
the next attempt waits 5 seconds doubled per consecutive failure up to 10
minutes, ±20% jitter, or the `Retry-After` when that is longer (`outcomes.json`,
`backoff.json`). Failures are counted in memory, so a restarted client sends
what is waiting at once. An event whose batch was delivered but not yet deleted
when the app died is sent again and counted by the server as a duplicate.
