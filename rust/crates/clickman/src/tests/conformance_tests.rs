//! Every case of the client fixtures in protocol/fixtures, through the rule and
//! through the client or store that applies it.

use rusqlite::params;
use serde_json::{Map, Value, json};

use crate::Error;
use crate::backoff;
use crate::batch::{self, Urgency};
use crate::clock::unix_millis;
use crate::identity;
use crate::launch::{self, Release};
use crate::outcome::Outcome;
use crate::store::Store;
use crate::tests::support::{Harness, START, fixture, scratch_config, status};

fn cases(file: &str) -> Vec<Value> {
    let cases = fixture(file)["cases"].as_array().unwrap().clone();
    assert!(!cases.is_empty(), "{file} has no cases");
    cases
}

fn name(case: &Value) -> &str {
    case["name"].as_str().unwrap()
}

fn object(value: &Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn count(case: &Value, key: &str) -> usize {
    usize::try_from(case[key].as_u64().unwrap()).unwrap()
}

#[test]
fn events_json_decides_what_is_stored() {
    for case in cases("events.json") {
        let harness = Harness::new();
        let value = case["value"].as_str().unwrap();
        let valid = case["valid"].as_bool().unwrap();
        match case["field"].as_str().unwrap() {
            "event" => check_event(&harness, value, valid, name(&case)),
            "externalId" => check_external_id(&harness, value, valid, name(&case)),
            field => panic!("{}: no such field {field}", name(&case)),
        }
    }
}

fn check_event(harness: &Harness, value: &str, valid: bool, name: &str) {
    let tracked = harness.clickman.track(value, json!({}));
    assert_eq!(tracked.is_ok(), valid, "{name}");
    assert!(
        valid || matches!(tracked, Err(Error::InvalidEvent)),
        "{name}"
    );
    let stored = if valid {
        vec![value.to_owned()]
    } else {
        Vec::new()
    };
    assert_eq!(harness.stored_names(), stored, "{name}");
}

fn check_external_id(harness: &Harness, value: &str, valid: bool, name: &str) {
    let identified = harness.clickman.identify(value);
    assert_eq!(identified.is_ok(), valid, "{name}");
    assert!(
        valid || matches!(identified, Err(Error::InvalidExternalId)),
        "{name}"
    );
    harness.clickman.track("probe", json!({})).unwrap();
    let actor = if valid { value } else { "*" };
    assert_eq!(harness.stored()[0]["externalId"], actor, "{name}");
}

#[test]
fn traits_json_merges_into_the_stored_traits() {
    for case in cases("traits.json") {
        let merged = identity::merge(object(&case["stored"]), object(&case["changes"]));
        assert_eq!(merged, object(&case["traits"]), "{}", name(&case));
        let harness = Harness::new();
        harness.clickman.set_traits(case["stored"].clone()).unwrap();
        harness
            .clickman
            .set_traits(case["changes"].clone())
            .unwrap();
        let stored: String = harness
            .raw()
            .query_row("SELECT traits FROM identity", [], |row| row.get(0))
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&stored).unwrap(),
            case["traits"],
            "{}",
            name(&case)
        );
    }
}

#[test]
fn lifecycle_json_names_the_events_of_a_launch() {
    for case in cases("lifecycle.json") {
        let last = release(&case["last"]);
        let launch = release(&case["launch"]).unwrap();
        let rule: Vec<Value> = launch::events(last.as_ref(), &launch)
            .into_iter()
            .map(|(event, properties)| json!({"event": event, "properties": properties}))
            .collect();
        assert_eq!(Value::Array(rule), case["events"], "{}", name(&case));
        assert_eq!(
            recorded_launch(last, &launch),
            case["events"],
            "{}",
            name(&case)
        );
    }
}

fn release(value: &Value) -> Option<Release> {
    value.as_object().map(|release| Release {
        version: release["version"].as_str().unwrap().to_owned(),
        build: release["build"].as_str().unwrap().to_owned(),
    })
}

fn recorded_launch(last: Option<Release>, launch: &Release) -> Value {
    let harness = Harness::new();
    if let Some(last) = last {
        harness
            .clickman
            .app_launched(&last.version, &last.build)
            .unwrap();
    }
    let before = harness.stored().len();
    harness
        .clickman
        .app_launched(&launch.version, &launch.build)
        .unwrap();
    let recorded = harness.stored()[before..]
        .iter()
        .map(|body| json!({"event": body["event"], "properties": body["properties"]}))
        .collect();
    Value::Array(recorded)
}

#[test]
fn batches_json_cuts_the_oldest_waiting_events() {
    for case in cases("batches.json") {
        let bodies: Vec<&str> = case["bodies"]
            .as_array()
            .unwrap()
            .iter()
            .map(|body| body.as_str().unwrap())
            .collect();
        let (max_events, max_bytes) = (count(&case, "maxEvents"), count(&case, "maxBytes"));
        let taken = count(&case, "taken");
        assert_eq!(
            batch::taken(bodies.iter().copied(), max_events, max_bytes),
            taken,
            "{}",
            name(&case)
        );
        assert_eq!(
            taken_from_a_store(&bodies, max_events, max_bytes),
            bodies[..taken],
            "{}",
            name(&case)
        );
    }
}

fn taken_from_a_store(bodies: &[&str], max_events: usize, max_bytes: usize) -> Vec<String> {
    let dir = tempfile::tempdir().unwrap();
    let mut config = scratch_config(&dir);
    config.max_batch_events = max_events;
    config.max_batch_bytes = max_bytes;
    let now = unix_millis(START);
    let store = Store::open(&config.path).unwrap();
    store
        .write(|transaction| {
            for body in bodies {
                transaction.execute(
                    "INSERT INTO events (created_at, body) VALUES (?1, ?2)",
                    params![now, body],
                )?;
            }
            batch::take(transaction, &config, now, Urgency::Forced)
        })
        .unwrap()
        .unwrap()
        .bodies
}

#[tokio::test]
async fn outcomes_json_decides_what_stays_queued() {
    for case in cases("outcomes.json") {
        let code = u16::try_from(case["status"].as_u64().unwrap()).unwrap();
        let (outcome, left) = match case["outcome"].as_str().unwrap() {
            "delivered" => (Outcome::Delivered, 0),
            "refused" => (Outcome::Refused, 0),
            "retry" => (Outcome::Retry, 1),
            other => panic!("{}: no such outcome {other}", name(&case)),
        };
        assert_eq!(Outcome::of(code), outcome, "{}", name(&case));
        let answer = if code == 0 {
            Err("no response".to_owned())
        } else {
            Ok(status(code))
        };
        let harness = Harness::with(|_| {}, [answer]);
        harness.clickman.track("probe", json!({})).unwrap();
        harness.clickman.flush().await.unwrap();
        assert_eq!(harness.clickman.pending().unwrap(), left, "{}", name(&case));
    }
}

#[test]
fn backoff_json_bounds_the_next_attempt() {
    for case in cases("backoff.json") {
        let failures = u32::try_from(case["failures"].as_u64().unwrap()).unwrap();
        let header = case["retryAfter"]
            .as_u64()
            .map(|seconds| seconds.to_string());
        let advice = backoff::retry_after(header.as_deref());
        let (min, max) = (case["min"].as_f64().unwrap(), case["max"].as_f64().unwrap());
        let [lowest, middle, highest] = [0.0, 0.5, 1.0 - f64::EPSILON]
            .map(|random| backoff::delay(failures, advice, random).as_secs_f64());
        assert!(
            (lowest - min).abs() < 1e-9,
            "{}: the lowest factor gives {lowest}",
            name(&case)
        );
        assert!(min <= middle && middle <= max, "{}: {middle}", name(&case));
        assert!(
            highest <= max && max - highest < 0.01,
            "{}: the highest factor gives {highest}",
            name(&case)
        );
    }
}
