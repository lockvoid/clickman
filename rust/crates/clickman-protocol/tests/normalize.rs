use clickman_protocol::{BatchError, Limits, Reason, Sanitizer, normalize};
use serde_json::{Value, json};
use time::macros::datetime;
use time::{Duration, OffsetDateTime};

const RECEIVED_AT: OffsetDateTime = datetime!(2026-09-23 15:04:10 UTC);

fn event(overrides: Value) -> Value {
    let mut event = json!({
        "type": "track",
        "messageId": "01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f",
        "event": "export_completed",
        "externalId": "user_42",
        "timestamp": "2026-09-23T15:03:59.004Z",
        "properties": { "format": "mp4" },
    });
    for (key, value) in overrides.as_object().unwrap() {
        if value.is_null() {
            event.as_object_mut().unwrap().remove(key);
        } else {
            event[key] = value.clone();
        }
    }
    event
}

fn batch(events: Vec<Value>) -> Vec<u8> {
    serde_json::to_vec(&json!({ "sentAt": "2026-09-23T15:04:05.000Z", "batch": events })).unwrap()
}

fn run(body: &[u8]) -> Result<clickman_protocol::Normalized, BatchError> {
    normalize(body, RECEIVED_AT, &Sanitizer::default(), &Limits::default())
}

#[test]
fn a_valid_event_is_accepted_with_the_client_clock_corrected() {
    let normalized = run(&batch(vec![event(json!({}))])).unwrap();

    assert!(normalized.rejected.is_empty());
    let accepted = &normalized.events[0];
    assert_eq!(
        accepted.message_id.to_string(),
        "01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f"
    );
    assert_eq!(accepted.event, "export_completed");
    assert_eq!(accepted.external_id, "user_42");
    assert_eq!(accepted.occurred_at, datetime!(2026-09-23 15:04:04.004 UTC));
    assert_eq!(accepted.properties["format"], "mp4");
}

#[test]
fn the_batch_context_merges_under_the_event_context_and_both_flatten() {
    let body = serde_json::to_vec(&json!({
        "sentAt": "2026-09-23T15:04:05.000Z",
        "context": { "library": { "name": "clickman-swift" }, "os": { "name": "iOS", "version": "26.0" } },
        "batch": [event(json!({ "context": { "os": { "version": "26.1" } } }))],
    }))
    .unwrap();

    let accepted = &run(&body).unwrap().events[0];

    assert_eq!(accepted.context["library.name"], "clickman-swift");
    assert_eq!(accepted.context["os.name"], "iOS");
    assert_eq!(accepted.context["os.version"], "26.1");
}

#[test]
fn properties_and_context_are_sanitized() {
    let body = serde_json::to_vec(&json!({
        "sentAt": "2026-09-23T15:04:05.000Z",
        "batch": [event(json!({
            "properties": { "email": "a@b.co", "note": "+7 999 123 45 67" },
            "context": { "traits": { "first_name": "Anna" } },
        }))],
    }))
    .unwrap();

    let accepted = &run(&body).unwrap().events[0];

    assert_eq!(accepted.properties["email"], "[FILTERED]");
    assert_eq!(accepted.properties["note"], "[FILTERED]");
    assert_eq!(accepted.context["traits.first_name"], "[FILTERED]");
}

#[test]
fn a_missing_properties_object_is_an_empty_one() {
    let accepted = &run(&batch(vec![event(json!({ "properties": null }))]))
        .unwrap()
        .events[0];

    assert!(accepted.properties.is_empty());
}

#[test]
fn each_invalid_event_is_rejected_with_its_reason_and_the_rest_are_kept() {
    let cases = [
        (json!({ "type": "identify" }), Reason::UnsupportedType),
        (json!({ "type": null }), Reason::UnsupportedType),
        (
            json!({ "messageId": "not-a-uuid" }),
            Reason::InvalidMessageId,
        ),
        (json!({ "event": "" }), Reason::InvalidEvent),
        (json!({ "event": "x".repeat(201) }), Reason::InvalidEvent),
        (json!({ "event": "bad\nname" }), Reason::InvalidEvent),
        (json!({ "externalId": "" }), Reason::InvalidExternalId),
        (json!({ "externalId": 42 }), Reason::InvalidExternalId),
        (
            json!({ "timestamp": "yesterday" }),
            Reason::InvalidTimestamp,
        ),
        (
            json!({ "timestamp": "2026-09-23T17:10:00Z" }),
            Reason::TimestampOutOfRange,
        ),
        (
            json!({ "timestamp": "2026-05-01T00:00:00Z" }),
            Reason::TimestampOutOfRange,
        ),
        (json!({ "properties": [1, 2] }), Reason::InvalidProperties),
        (
            json!({ "properties": { "": 1 } }),
            Reason::InvalidProperties,
        ),
        (
            json!({ "properties": { "k".repeat(129): 1 } }),
            Reason::InvalidProperties,
        ),
        (json!({ "context": "iOS" }), Reason::InvalidContext),
    ];

    for (overrides, reason) in cases {
        let normalized = run(&batch(vec![
            event(overrides.clone()),
            event(json!({ "messageId": "01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e60" })),
        ]))
        .unwrap();

        assert_eq!(normalized.events.len(), 1, "{overrides}");
        assert_eq!(normalized.rejected.len(), 1, "{overrides}");
        assert_eq!(normalized.rejected[0].index, 0, "{overrides}");
        assert_eq!(normalized.rejected[0].reason, reason, "{overrides}");
    }
}

#[test]
fn a_rejection_names_the_message_id_when_it_has_one() {
    let normalized = run(&batch(vec![event(json!({ "event": "" }))])).unwrap();

    assert_eq!(
        normalized.rejected[0].message_id.as_deref(),
        Some("01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f")
    );
}

#[test]
fn too_many_keys_is_its_own_reason() {
    let properties: serde_json::Map<String, Value> = (0..129)
        .map(|index| (format!("k{index}"), json!(index)))
        .collect();
    let context: serde_json::Map<String, Value> = (0..65)
        .map(|index| (format!("c{index}"), json!(index)))
        .collect();

    let normalized = run(&batch(vec![
        event(json!({ "properties": properties })),
        event(json!({ "context": context, "messageId": "01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e60" })),
    ]))
    .unwrap();

    assert_eq!(
        normalized
            .rejected
            .iter()
            .map(|rejection| rejection.reason)
            .collect::<Vec<_>>(),
        vec![Reason::TooManyKeys, Reason::TooManyKeys]
    );
}

#[test]
fn the_age_limit_follows_the_limits() {
    let limits = Limits {
        max_event_age: Duration::days(200),
        ..Limits::default()
    };

    let normalized = normalize(
        &batch(vec![event(json!({ "timestamp": "2026-05-01T00:00:00Z" }))]),
        RECEIVED_AT,
        &Sanitizer::default(),
        &limits,
    )
    .unwrap();

    assert!(normalized.rejected.is_empty());
}

#[test]
fn a_malformed_batch_is_refused_as_a_whole() {
    let bodies: [&[u8]; 7] = [
        b"not json",
        b"[]",
        br#"{"batch": []}"#,
        br#"{"sentAt": "2026-09-23T15:04:05Z"}"#,
        br#"{"sentAt": "later", "batch": [{}]}"#,
        br#"{"sentAt": "2026-09-23T15:04:05Z", "batch": []}"#,
        br#"{"sentAt": "2026-09-23T15:04:05Z", "batch": [{}], "context": 1}"#,
    ];

    for body in bodies {
        assert!(
            matches!(run(body), Err(BatchError::Malformed(_))),
            "{}",
            String::from_utf8_lossy(body)
        );
    }
}

#[test]
fn a_batch_over_the_event_limit_is_refused() {
    let events = (0..501).map(|_| event(json!({}))).collect();

    assert!(matches!(run(&batch(events)), Err(BatchError::Malformed(_))));
}
