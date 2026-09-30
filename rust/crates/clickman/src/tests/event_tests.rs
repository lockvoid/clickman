use std::time::Duration;

use serde_json::json;
use uuid::Variant;

use crate::Error;
use crate::clock::unix_millis;
use crate::event::is_valid_text;
use crate::tests::support::{Harness, START};

#[test]
fn a_tracked_body_carries_the_protocol_fields_in_order() {
    let harness = Harness::new();
    harness
        .clickman
        .set_context(json!({"os": {"name": "macOS", "version": "26.1"}}))
        .unwrap();
    let message_id = harness
        .clickman
        .track(
            "export_completed",
            json!({"format": "mp4", "duration": 32.5}),
        )
        .unwrap();
    let body = &harness.stored()[0];
    let keys: Vec<&str> = body
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        [
            "type",
            "messageId",
            "event",
            "externalId",
            "timestamp",
            "properties",
            "context"
        ]
    );
    let library = json!({"name": "clickman-rust", "version": env!("CARGO_PKG_VERSION")});
    let expected = json!({
        "type": "track",
        "messageId": message_id.to_string(),
        "event": "export_completed",
        "externalId": "*",
        "timestamp": "2026-09-30T12:00:00.123Z",
        "properties": {"format": "mp4", "duration": 32.5},
        "context": {"os": {"name": "macOS", "version": "26.1"}, "library": library},
    });
    assert_eq!(body, &expected);
}

#[test]
fn every_event_gets_a_new_uuid_v7_in_lowercase_hyphenated_text() {
    let harness = Harness::new();
    let first = harness.clickman.track("first", json!({})).unwrap();
    let second = harness.clickman.track("second", json!({})).unwrap();
    for message_id in [first, second] {
        assert_eq!(message_id.get_version_num(), 7);
        assert_eq!(message_id.get_variant(), Variant::RFC4122);
    }
    assert!(first < second);
    let texts: Vec<String> = harness
        .stored()
        .iter()
        .map(|body| body["messageId"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(texts, [first.to_string(), second.to_string()]);
    let text = &texts[0];
    assert_eq!(text.len(), 36);
    assert!(
        text.chars()
            .all(|char| char == '-' || char.is_ascii_digit() || ('a'..='f').contains(&char))
    );
    assert_eq!(&text[14..15], "7");
}

#[test]
fn created_at_and_the_timestamp_are_the_clock_in_milliseconds() {
    let harness = Harness::new();
    harness.clock.advance(Duration::from_millis(1_234));
    harness.clickman.track("later", json!({})).unwrap();
    let created_at: i64 = harness
        .raw()
        .query_row("SELECT created_at FROM events", [], |row| row.get(0))
        .unwrap();
    assert_eq!(created_at, unix_millis(START) + 1_234);
    assert_eq!(harness.stored()[0]["timestamp"], "2026-09-30T12:00:01.357Z");
}

#[test]
fn the_context_carries_the_traits_only_when_there_are_some() {
    let harness = Harness::new();
    harness.clickman.track("before", json!({})).unwrap();
    harness.clickman.set_traits(json!({"plan": "pro"})).unwrap();
    harness.clickman.track("after", json!({})).unwrap();
    let stored = harness.stored();
    assert_eq!(stored[0]["context"].get("traits"), None);
    assert_eq!(stored[1]["context"]["traits"], json!({"plan": "pro"}));
}

#[test]
fn an_invalid_name_is_refused_and_nothing_is_stored() {
    let harness = Harness::new();
    for name in [String::new(), "export\u{7}".to_owned(), "x".repeat(201)] {
        assert!(
            matches!(
                harness.clickman.track(&name, json!({})),
                Err(Error::InvalidEvent)
            ),
            "{name:?}"
        );
    }
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[test]
fn the_newest_event_drops_the_oldest_beyond_max_queue() {
    let harness = Harness::with(|config| config.max_queue = 3, []);
    for index in 0..5 {
        harness
            .clickman
            .track(&format!("event_{index}"), json!({}))
            .unwrap();
    }
    assert_eq!(harness.stored_names(), ["event_2", "event_3", "event_4"]);
}

#[test]
fn a_refused_event_trims_nothing() {
    let harness = Harness::with(|config| config.max_queue = 1, []);
    harness.clickman.track("kept", json!({})).unwrap();
    assert!(harness.clickman.track("", json!({})).is_err());
    assert_eq!(harness.stored_names(), ["kept"]);
}

#[test]
fn names_are_counted_in_unicode_scalar_values_not_bytes() {
    assert!(is_valid_text(&"é".repeat(200), 200));
    assert!(!is_valid_text(&"é".repeat(201), 200));
    assert!(!is_valid_text("\u{85}", 200));
}
