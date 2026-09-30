use std::time::Duration;

use rusqlite::params;
use serde_json::Value;
use tempfile::TempDir;

use crate::Config;
use crate::batch::{self, Batch, Urgency};
use crate::clock::{millis, unix_millis};
use crate::store::Store;
use crate::tests::support::{START, scratch_config};

fn now() -> i64 {
    unix_millis(START)
}

fn max_age() -> i64 {
    millis(Duration::from_secs(30 * 24 * 60 * 60))
}

struct Queue {
    store: Store,
    config: Config,
    _dir: TempDir,
}

fn queue(configure: impl FnOnce(&mut Config)) -> Queue {
    let dir = tempfile::tempdir().unwrap();
    let mut config = scratch_config(&dir);
    configure(&mut config);
    let store = Store::open(&config.path).unwrap();
    Queue {
        store,
        config,
        _dir: dir,
    }
}

impl Queue {
    fn insert(&self, body: &str, created_at: i64) {
        let sql = "INSERT INTO events (created_at, body) VALUES (?1, ?2)";
        self.store
            .write(|transaction| Ok(transaction.execute(sql, params![created_at, body])?))
            .unwrap();
    }

    fn take(&self, now: i64, urgency: Urgency) -> Option<Batch> {
        self.store
            .write(|transaction| batch::take(transaction, &self.config, now, urgency))
            .unwrap()
    }

    fn bodies(&self) -> Vec<String> {
        let rows = self.store.read(|connection| {
            let mut statement = connection.prepare("SELECT body FROM events ORDER BY seq")?;
            let bodies = statement.query_map([], |row| row.get(0))?;
            Ok(bodies.collect::<rusqlite::Result<_>>()?)
        });
        rows.unwrap()
    }
}

#[test]
fn nothing_waiting_is_no_batch_even_forced() {
    assert_eq!(queue(|_| {}).take(now(), Urgency::Forced), None);
}

#[test]
fn a_few_young_events_are_due_only_when_forced() {
    let queue = queue(|config| config.flush_at = 3);
    queue.insert("{}", now());
    queue.insert("{}", now());
    assert_eq!(queue.take(now(), Urgency::Due), None);
    assert_eq!(
        queue
            .take(now(), Urgency::Forced)
            .map(|batch| batch.bodies.len()),
        Some(2)
    );
}

#[test]
fn flush_at_waiting_events_are_due() {
    let queue = queue(|config| config.flush_at = 3);
    for _ in 0..3 {
        queue.insert("{}", now());
    }
    assert_eq!(
        queue
            .take(now(), Urgency::Due)
            .map(|batch| batch.bodies.len()),
        Some(3)
    );
}

#[test]
fn the_oldest_event_is_due_once_it_has_waited_flush_interval() {
    let queue = queue(|_| {});
    queue.insert("{}", now());
    let interval = millis(Duration::from_secs(30));
    assert_eq!(queue.take(now() + interval - 1, Urgency::Due), None);
    assert!(queue.take(now() + interval, Urgency::Due).is_some());
}

#[test]
fn events_past_max_age_are_deleted_unsent_before_a_batch_is_taken() {
    let queue = queue(|_| {});
    queue.insert(r#"{"n":"expired"}"#, now() - max_age() - 1);
    queue.insert(r#"{"n":"exactly max_age old"}"#, now() - max_age());
    let batch = queue.take(now(), Urgency::Forced).unwrap();
    assert_eq!(batch.bodies, [r#"{"n":"exactly max_age old"}"#]);
    assert_eq!(queue.bodies(), [r#"{"n":"exactly max_age old"}"#]);
}

#[test]
fn expired_events_go_even_when_nothing_is_due() {
    let queue = queue(|_| {});
    queue.insert("{}", now() - max_age() - 1);
    assert_eq!(queue.take(now(), Urgency::Due), None);
    assert!(queue.bodies().is_empty());
}

#[test]
fn a_batch_takes_the_oldest_events_within_the_limits_and_names_the_newest() {
    let queue = queue(|config| config.max_batch_events = 2);
    for body in [r#"{"n":1}"#, r#"{"n":2}"#, r#"{"n":3}"#] {
        queue.insert(body, now());
    }
    let batch = queue.take(now(), Urgency::Forced).unwrap();
    assert_eq!(batch.bodies, [r#"{"n":1}"#, r#"{"n":2}"#]);
    assert_eq!(batch.last_seq, 2);
}

#[test]
fn removing_a_batch_keeps_the_events_tracked_since() {
    let queue = queue(|config| config.max_batch_events = 2);
    for body in [r#"{"n":1}"#, r#"{"n":2}"#, r#"{"n":3}"#] {
        queue.insert(body, now());
    }
    let batch = queue.take(now(), Urgency::Forced).unwrap();
    queue.insert(r#"{"n":4}"#, now());
    queue
        .store
        .write(|transaction| batch::remove(transaction, &batch))
        .unwrap();
    assert_eq!(queue.bodies(), [r#"{"n":3}"#, r#"{"n":4}"#]);
}

#[test]
fn the_payload_carries_sent_at_and_the_bodies_verbatim() {
    let bodies = vec![r#"{"a": 1}"#.to_owned(), r#"{"b":"é"}"#.to_owned()];
    let payload = Batch {
        last_seq: 2,
        bodies,
    }
    .payload("2026-09-30T12:00:00.123Z");
    assert_eq!(
        payload,
        r#"{"sentAt":"2026-09-30T12:00:00.123Z","batch":[{"a": 1},{"b":"é"}]}"#
    );
    assert!(serde_json::from_str::<Value>(&payload).is_ok());
}

#[test]
fn pending_counts_every_waiting_event() {
    let queue = queue(|_| {});
    assert_eq!(queue.store.read(batch::pending).unwrap(), 0);
    queue.insert("{}", now());
    queue.insert("{}", now());
    assert_eq!(queue.store.read(batch::pending).unwrap(), 2);
}

#[test]
fn no_bodies_make_no_batch() {
    assert_eq!(batch::taken([], 100, 900_000), 0);
}
