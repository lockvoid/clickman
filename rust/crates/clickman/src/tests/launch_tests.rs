use serde_json::{Value, json};

use crate::tests::support::Harness;

fn last_launch(harness: &Harness) -> (Option<String>, Option<String>) {
    harness
        .raw()
        .query_row("SELECT app_version, app_build FROM identity", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap()
}

#[test]
fn a_launch_is_remembered_as_the_last_launch() {
    let harness = Harness::new();
    assert_eq!(last_launch(&harness), (None, None));
    harness.clickman.app_launched("1.0", "10").unwrap();
    assert_eq!(
        last_launch(&harness),
        (Some("1.0".to_owned()), Some("10".to_owned()))
    );
}

#[test]
fn each_launch_opens_the_app_once() {
    let harness = Harness::new();
    harness.clickman.app_launched("1.0", "10").unwrap();
    harness.clickman.app_launched("1.0", "10").unwrap();
    harness.clickman.app_launched("1.1", "11").unwrap();
    let names = [
        "app_installed",
        "app_opened",
        "app_opened",
        "app_updated",
        "app_opened",
    ];
    assert_eq!(harness.stored_names(), names);
}

#[test]
fn half_a_remembered_launch_is_no_launch() {
    let harness = Harness::new();
    harness
        .raw()
        .execute("UPDATE identity SET app_version = '1.0'", [])
        .unwrap();
    harness.clickman.app_launched("1.0", "10").unwrap();
    assert_eq!(harness.stored_names(), ["app_installed", "app_opened"]);
}

#[test]
fn launch_events_are_stamped_like_any_event() {
    let harness = Harness::new();
    harness.clickman.identify("user_7").unwrap();
    harness.clickman.set_traits(json!({"plan": "pro"})).unwrap();
    harness.clickman.app_launched("1.0", "10").unwrap();
    for body in harness.stored() {
        assert_eq!(body["type"], "track");
        assert_eq!(body["externalId"], "user_7");
        assert_eq!(body["timestamp"], "2026-09-30T12:00:00.123Z");
        assert_eq!(body["context"]["traits"], json!({"plan": "pro"}));
    }
}

#[test]
fn a_launch_trims_the_queue_like_any_event() {
    let harness = Harness::with(|config| config.max_queue = 1, []);
    harness.clickman.app_launched("1.0", "10").unwrap();
    let properties: Vec<Value> = harness
        .stored()
        .iter()
        .map(|body| body["properties"].clone())
        .collect();
    assert_eq!(harness.stored_names(), ["app_opened"]);
    assert_eq!(properties, [json!({"from_background": false})]);
}
