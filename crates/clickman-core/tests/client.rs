use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

use clickman_core::{Batch, Client, Config, Error};
use flate2::read::GzDecoder;
use serde_json::{Value, json};
use time::OffsetDateTime;
use time::macros::datetime;

const T0: OffsetDateTime = datetime!(2026-09-23 12:00:00 UTC);

struct Store {
    path: PathBuf,
}

impl Store {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("clickman-core-{}.sqlite", uuid::Uuid::now_v7()));
        Self { path }
    }

    fn open(&self, config: Config) -> Client {
        Client::open(&self.path, config).unwrap()
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.path.display()));
        }
    }
}

fn at(seconds: i64) -> OffsetDateTime {
    T0 + time::Duration::seconds(seconds)
}

fn track(client: &Client, name: &str, seconds: i64) {
    client
        .track(name, Some(json!({ "n": name })), None, at(seconds))
        .unwrap();
}

fn decode(batch: &Batch) -> Value {
    let mut json = String::new();
    GzDecoder::new(batch.body.as_slice())
        .read_to_string(&mut json)
        .unwrap();
    serde_json::from_str(&json).unwrap()
}

fn names(batch: &Batch) -> Vec<String> {
    decode(batch)["batch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["event"].as_str().unwrap().to_owned())
        .collect()
}

fn config() -> Config {
    Config {
        flush_at: 3,
        ..Config::default()
    }
}

#[test]
fn a_batch_is_due_once_enough_events_are_pending() {
    let store = Store::new();
    let client = store.open(config());

    track(&client, "a", 0);
    track(&client, "b", 0);
    assert!(client.take_batch(at(1), false).unwrap().is_none());

    track(&client, "c", 0);
    let batch = client.take_batch(at(1), false).unwrap().unwrap();

    assert_eq!(batch.events, 3);
    assert_eq!(names(&batch), ["a", "b", "c"]);
}

#[test]
fn every_batch_is_accepted_by_the_server_protocol() {
    let store = Store::new();
    let client = store.open(config());
    client.identify("user_42").unwrap();
    client.set_context(json!({ "os": { "name": "iOS", "version": "26.1" }, "library": { "name": "clickman-swift" } })).unwrap();
    client
        .track(
            "export_completed",
            Some(json!({ "format": "mp4", "size": { "width": 1080 } })),
            None,
            at(0),
        )
        .unwrap();
    client
        .track("paywall_viewed", None, Some(at(-5)), at(0))
        .unwrap();

    let batch = client.take_batch(at(2), true).unwrap().unwrap();
    let body = serde_json::to_vec(&decode(&batch)).unwrap();
    let normalized = clickman_protocol::normalize(
        &body,
        at(2),
        &clickman_protocol::Sanitizer::default(),
        &clickman_protocol::Limits::default(),
    )
    .unwrap();

    assert!(normalized.rejected.is_empty(), "{:?}", normalized.rejected);
    assert_eq!(normalized.events.len(), 2);
    let export = &normalized.events[0];
    assert_eq!(export.event, "export_completed");
    assert_eq!(export.external_id, "user_42");
    assert_eq!(export.properties["size.width"], 1080);
    assert_eq!(export.context["os.name"], "iOS");
    assert_eq!(normalized.events[1].occurred_at, at(-5));
}

#[test]
fn the_oldest_event_waiting_long_enough_makes_a_batch_due() {
    let store = Store::new();
    let client = store.open(Config {
        flush_at: 20,
        flush_interval: Duration::from_secs(30),
        ..Config::default()
    });

    track(&client, "a", 0);

    assert!(client.take_batch(at(29), false).unwrap().is_none());
    assert!(client.take_batch(at(30), false).unwrap().is_some());
}

#[test]
fn force_sends_whatever_is_pending_and_nothing_when_empty() {
    let store = Store::new();
    let client = store.open(Config {
        flush_at: 20,
        ..Config::default()
    });

    assert!(client.take_batch(at(0), true).unwrap().is_none());
    track(&client, "a", 0);

    assert_eq!(client.take_batch(at(0), true).unwrap().unwrap().events, 1);
}

#[test]
fn a_batch_in_flight_is_not_handed_out_again_until_its_lease_ends() {
    let store = Store::new();
    let client = store.open(Config {
        lease: Duration::from_secs(60),
        ..config()
    });
    for name in ["a", "b", "c"] {
        track(&client, name, 0);
    }

    let first = client.take_batch(at(0), true).unwrap().unwrap();
    assert!(client.take_batch(at(59), true).unwrap().is_none());

    let again = client.take_batch(at(60), true).unwrap().unwrap();
    assert_ne!(again.id, first.id);
    assert_eq!(names(&again), ["a", "b", "c"]);
}

#[test]
fn a_delivered_batch_leaves_the_queue() {
    let store = Store::new();
    let client = store.open(config());
    for name in ["a", "b", "c"] {
        track(&client, name, 0);
    }

    let batch = client.take_batch(at(0), false).unwrap().unwrap();
    client.complete(batch.id, 202, None, at(1)).unwrap();

    assert_eq!(client.pending().unwrap(), 0);
}

#[test]
fn a_permanently_refused_batch_is_dropped() {
    for status in [400, 413, 415] {
        let store = Store::new();
        let client = store.open(config());
        for name in ["a", "b", "c"] {
            track(&client, name, 0);
        }

        let batch = client.take_batch(at(0), false).unwrap().unwrap();
        client.complete(batch.id, status, None, at(1)).unwrap();

        assert_eq!(client.pending().unwrap(), 0, "{status}");
    }
}

#[test]
fn a_failed_batch_returns_to_the_queue_and_waits_out_a_growing_backoff() {
    let store = Store::new();
    let client = store.open(Config {
        backoff_base: Duration::from_secs(10),
        ..config()
    });
    for name in ["a", "b", "c"] {
        track(&client, name, 0);
    }

    let first = client.take_batch(at(0), true).unwrap().unwrap();
    client.complete(first.id, 503, None, at(0)).unwrap();
    assert_eq!(client.pending().unwrap(), 3);
    assert!(
        client.take_batch(at(7), true).unwrap().is_none(),
        "10s -20% jitter is at least 8s"
    );

    let second = client.take_batch(at(13), true).unwrap().unwrap();
    client.complete(second.id, 0, None, at(13)).unwrap();
    assert!(
        client.take_batch(at(13 + 15), true).unwrap().is_none(),
        "20s -20% jitter is at least 16s"
    );
    assert!(
        client.take_batch(at(13 + 25), true).unwrap().is_some(),
        "20s +20% jitter is at most 24s"
    );
}

#[test]
fn a_delivery_resets_the_backoff() {
    let store = Store::new();
    let client = store.open(Config {
        backoff_base: Duration::from_secs(10),
        ..config()
    });
    for name in ["a", "b", "c"] {
        track(&client, name, 0);
    }
    let failed = client.take_batch(at(0), true).unwrap().unwrap();
    client.complete(failed.id, 500, None, at(0)).unwrap();
    let delivered = client.take_batch(at(20), true).unwrap().unwrap();
    client.complete(delivered.id, 202, None, at(20)).unwrap();

    track(&client, "d", 21);

    assert!(client.take_batch(at(21), true).unwrap().is_some());
}

#[test]
fn retry_after_is_honored_when_longer_than_the_backoff() {
    let store = Store::new();
    let client = store.open(config());
    for name in ["a", "b", "c"] {
        track(&client, name, 0);
    }

    let batch = client.take_batch(at(0), true).unwrap().unwrap();
    client
        .complete(batch.id, 429, Some(Duration::from_secs(120)), at(0))
        .unwrap();

    assert!(client.take_batch(at(119), true).unwrap().is_none());
    assert!(client.take_batch(at(120), true).unwrap().is_some());
}

#[test]
fn a_completion_for_an_unknown_batch_changes_nothing() {
    let store = Store::new();
    let client = store.open(config());
    track(&client, "a", 0);

    client.complete(9_999, 202, None, at(0)).unwrap();

    assert_eq!(client.pending().unwrap(), 1);
}

#[test]
fn identify_and_reset_set_the_actor_of_later_events() {
    let store = Store::new();
    let client = store.open(config());

    assert_eq!(client.external_id().unwrap(), "*");
    track(&client, "anonymous", 0);
    client.identify("user_7").unwrap();
    track(&client, "signed_in", 0);
    client.reset().unwrap();
    track(&client, "signed_out", 0);

    let batch = client.take_batch(at(0), true).unwrap().unwrap();
    let actors: Vec<String> = decode(&batch)["batch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["externalId"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(actors, ["*", "user_7", "*"]);
}

#[test]
fn the_context_is_captured_when_the_event_is_tracked() {
    let store = Store::new();
    let client = store.open(config());

    client
        .set_context(json!({ "app": { "version": "1.40" } }))
        .unwrap();
    track(&client, "a", 0);
    client
        .set_context(json!({ "app": { "version": "1.41" } }))
        .unwrap();
    track(&client, "b", 0);

    let batch = client.take_batch(at(0), true).unwrap().unwrap();
    let versions: Vec<String> = decode(&batch)["batch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| {
            event["context"]["app"]["version"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    assert_eq!(versions, ["1.40", "1.41"]);
}

fn events(batch: &Batch) -> Vec<(String, Value)> {
    decode(batch)["batch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| {
            (
                event["event"].as_str().unwrap().to_owned(),
                event["properties"].clone(),
            )
        })
        .collect()
}

#[test]
fn the_first_launch_is_an_install_and_every_launch_an_open() {
    let store = Store::new();
    let client = store.open(config());

    client.app_launched("1.40", "140", at(0)).unwrap();
    client.app_launched("1.40", "140", at(60)).unwrap();

    let batch = client.take_batch(at(60), true).unwrap().unwrap();
    assert_eq!(
        events(&batch),
        [
            (
                "app_installed".to_owned(),
                json!({ "version": "1.40", "build": "140" })
            ),
            ("app_opened".to_owned(), json!({ "from_background": false })),
            ("app_opened".to_owned(), json!({ "from_background": false })),
        ]
    );
}

#[test]
fn the_first_launch_of_a_new_build_is_an_update_from_the_one_before() {
    let store = Store::new();
    store
        .open(config())
        .app_launched("1.40", "140", at(0))
        .unwrap();
    let client = store.open(config());
    client.take_batch(at(0), true).unwrap().unwrap();
    client.complete(1, 202, None, at(0)).unwrap();

    client.app_launched("1.41", "141", at(60)).unwrap();
    client.app_launched("1.41", "141", at(120)).unwrap();

    let batch = client.take_batch(at(120), true).unwrap().unwrap();
    assert_eq!(
        events(&batch),
        [
            (
                "app_updated".to_owned(),
                json!({ "version": "1.41", "build": "141", "previous_version": "1.40", "previous_build": "140" })
            ),
            ("app_opened".to_owned(), json!({ "from_background": false })),
            ("app_opened".to_owned(), json!({ "from_background": false })),
        ]
    );
}

#[test]
fn traits_ride_in_the_context_until_reset_and_survive_a_restart() {
    let store = Store::new();
    let client = store.open(config());

    client
        .set_context(json!({ "os": { "name": "iOS" } }))
        .unwrap();
    client
        .set_traits(json!({ "plan": "pro", "cohort": "a" }))
        .unwrap();
    track(&client, "a", 0);
    client
        .set_traits(json!({ "cohort": null, "region": "eu" }))
        .unwrap();
    drop(client);

    let client = store.open(config());
    track(&client, "b", 0);
    client.reset().unwrap();
    track(&client, "c", 0);

    let batch = client.take_batch(at(0), true).unwrap().unwrap();
    let contexts: Vec<Value> = decode(&batch)["batch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["context"].clone())
        .collect();
    assert_eq!(
        contexts,
        [
            json!({ "os": { "name": "iOS" }, "traits": { "plan": "pro", "cohort": "a" } }),
            json!({ "os": { "name": "iOS" }, "traits": { "plan": "pro", "region": "eu" } }),
            json!({ "os": { "name": "iOS" } }),
        ]
    );
}

#[test]
fn traits_and_versions_are_checked() {
    let store = Store::new();
    let client = store.open(config());

    assert!(matches!(
        client.set_traits(json!(["pro"])),
        Err(Error::InvalidTraits)
    ));
    assert!(matches!(
        client.app_launched("", "140", at(0)),
        Err(Error::InvalidVersion)
    ));
    assert_eq!(client.pending().unwrap(), 0);
}

#[test]
fn the_queue_keeps_the_newest_events_within_its_limit() {
    let store = Store::new();
    let client = store.open(Config {
        max_queue: 5,
        ..config()
    });

    for index in 1..=7 {
        track(&client, &format!("e{index}"), 0);
    }

    assert_eq!(client.pending().unwrap(), 5);
    assert_eq!(
        names(&client.take_batch(at(0), true).unwrap().unwrap()),
        ["e3", "e4", "e5", "e6", "e7"]
    );
}

#[test]
fn events_older_than_the_maximum_age_are_dropped() {
    let store = Store::new();
    let client = store.open(Config {
        max_age: Duration::from_secs(86_400),
        ..config()
    });
    track(&client, "old", 0);

    assert!(client.take_batch(at(2 * 86_400), true).unwrap().is_none());
    assert_eq!(client.pending().unwrap(), 0);
}

#[test]
fn a_batch_stays_under_its_byte_limit_and_the_rest_waits_for_the_next() {
    let store = Store::new();
    let client = store.open(Config {
        max_batch_bytes: 1_500,
        ..config()
    });
    let padding = "x".repeat(400);
    for index in 0..6 {
        client
            .track(
                &format!("e{index}"),
                Some(json!({ "padding": padding })),
                None,
                at(0),
            )
            .unwrap();
    }

    let first = client.take_batch(at(0), true).unwrap().unwrap();
    let mut json = Vec::new();
    GzDecoder::new(first.body.as_slice())
        .read_to_end(&mut json)
        .unwrap();
    assert!(json.len() <= 1_500, "{} bytes", json.len());
    assert!(first.events >= 1 && first.events < 6);

    client.complete(first.id, 202, None, at(0)).unwrap();
    let second = client.take_batch(at(0), true).unwrap().unwrap();
    assert_eq!(names(&second)[0], format!("e{}", first.events));
}

#[test]
fn the_queue_and_the_actor_survive_a_restart() {
    let store = Store::new();
    {
        let client = store.open(config());
        client.identify("user_9").unwrap();
        track(&client, "before_restart", 0);
    }

    let client = store.open(config());

    assert_eq!(client.pending().unwrap(), 1);
    assert_eq!(client.external_id().unwrap(), "user_9");
}

#[test]
fn invalid_input_is_refused() {
    let store = Store::new();
    let client = store.open(config());

    for name in ["", &"x".repeat(201), "bad\nname"] {
        assert!(
            matches!(
                client.track(name, None, None, at(0)),
                Err(Error::InvalidEvent(_))
            ),
            "{name:?}"
        );
    }
    assert!(matches!(
        client.track("a", Some(json!([1])), None, at(0)),
        Err(Error::InvalidProperties)
    ));
    for external_id in ["", &"x".repeat(257), "a\tb"] {
        assert!(
            matches!(client.identify(external_id), Err(Error::InvalidExternalId)),
            "{external_id:?}"
        );
    }
    assert!(matches!(
        client.set_context(json!("iOS")),
        Err(Error::InvalidContext)
    ));
    assert_eq!(client.pending().unwrap(), 0);
}

#[test]
fn a_config_reads_camel_case_json_with_milliseconds() {
    let config =
        Config::from_json(r#"{"flushAt": 5, "flushIntervalMs": 1000, "maxQueue": 50}"#).unwrap();

    assert_eq!(config.flush_at, 5);
    assert_eq!(config.flush_interval, Duration::from_secs(1));
    assert_eq!(config.max_queue, 50);
    assert_eq!(config.max_batch_events, Config::default().max_batch_events);
    assert!(matches!(
        Config::from_json(r#"{"flushAt": 0}"#),
        Err(Error::InvalidConfig(_))
    ));
    assert!(matches!(
        Config::from_json("[]"),
        Err(Error::InvalidConfig(_))
    ));
}
