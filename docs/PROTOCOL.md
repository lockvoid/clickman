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

A conforming client:

- stores events on the device before sending and survives restarts;
- sends a batch when 20 events are pending, when the oldest pending event is 30
  seconds old, when the application moves to the background and when the
  network returns;
- keeps at most 10,000 events and drops events older than 30 days, oldest
  first;
- retries with exponential backoff — 5 seconds doubled up to 10 minutes, ±20%
  jitter — and honors `Retry-After`;
- never sends more than 500 events or 1 MiB in one batch.
