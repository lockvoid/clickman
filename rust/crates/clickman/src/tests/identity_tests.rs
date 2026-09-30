use serde_json::{Map, Value, json};

use crate::Error;
use crate::identity::merge;
use crate::tests::support::Harness;

fn identity_row(harness: &Harness) -> (String, String) {
    harness
        .raw()
        .query_row("SELECT external_id, traits FROM identity", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap()
}

fn map(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn identify_makes_the_actor_of_later_events() {
    let harness = Harness::new();
    harness.clickman.track("before", json!({})).unwrap();
    harness.clickman.identify("user_42").unwrap();
    harness.clickman.track("after", json!({})).unwrap();
    let actors: Vec<Value> = harness
        .stored()
        .iter()
        .map(|body| body["externalId"].clone())
        .collect();
    assert_eq!(actors, [json!("*"), json!("user_42")]);
}

#[test]
fn a_refused_external_id_keeps_the_actor() {
    let harness = Harness::new();
    harness.clickman.identify("user_1").unwrap();
    assert!(matches!(
        harness.clickman.identify("4\n2"),
        Err(Error::InvalidExternalId)
    ));
    assert!(matches!(
        harness.clickman.identify(&"x".repeat(257)),
        Err(Error::InvalidExternalId)
    ));
    assert_eq!(identity_row(&harness).0, "user_1");
}

#[test]
fn reset_makes_later_events_anonymous_and_forgets_the_traits() {
    let harness = Harness::new();
    harness.clickman.identify("user_42").unwrap();
    harness.clickman.set_traits(json!({"plan": "pro"})).unwrap();
    harness.clickman.reset().unwrap();
    assert_eq!(identity_row(&harness), ("*".to_owned(), "{}".to_owned()));
    harness.clickman.track("after", json!({})).unwrap();
    let body = &harness.stored()[0];
    assert_eq!(body["externalId"], "*");
    assert_eq!(body["context"].get("traits"), None);
}

#[test]
fn traits_survive_identify() {
    let harness = Harness::new();
    harness.clickman.set_traits(json!({"plan": "pro"})).unwrap();
    harness.clickman.identify("user_42").unwrap();
    assert_eq!(
        identity_row(&harness),
        ("user_42".to_owned(), r#"{"plan":"pro"}"#.to_owned())
    );
}

#[test]
fn a_merge_keeps_the_order_of_the_remaining_traits() {
    let merged = merge(
        map(json!({"a": 1, "b": 2, "c": 3})),
        map(json!({"b": null, "d": 4, "a": 0})),
    );
    let keys: Vec<&str> = merged.keys().map(String::as_str).collect();
    assert_eq!(keys, ["a", "c", "d"]);
    assert_eq!(Value::Object(merged), json!({"a": 0, "c": 3, "d": 4}));
}

#[test]
fn stored_traits_that_are_not_an_object_fail_the_track() {
    let harness = Harness::new();
    harness
        .raw()
        .execute("UPDATE identity SET traits = '[1]'", [])
        .unwrap();
    assert!(matches!(
        harness.clickman.track("event", json!({})),
        Err(Error::StoredTraits(_))
    ));
    assert!(matches!(
        harness.clickman.set_traits(json!({"plan": "pro"})),
        Err(Error::StoredTraits(_))
    ));
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}
