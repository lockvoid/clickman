mod support;

use std::time::Duration;

use clickman::Config;
use serde_json::{Value, json};
use uuid::Uuid;

use support::{
    Answer, Received, StubServer, WRITE_KEY, answer, assert_rfc3339_millis, config, open, scratch,
};

/// Longer than the longest first backoff, 6 s.
const PAST_THE_FIRST_BACKOFF: Duration = Duration::from_millis(6_500);

#[tokio::test]
async fn a_tracked_event_reaches_the_server_gzipped_with_the_write_key() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let clickman = open(config(&server.endpoint, &dir));
    clickman
        .set_context(json!({"os": {"name": "macOS", "version": "26.1"}}))
        .unwrap();
    clickman.identify("user_42").unwrap();
    clickman.set_traits(json!({"plan": "pro"})).unwrap();
    let message_id = clickman
        .track("export_completed", json!({"format": "mp4"}))
        .unwrap();
    clickman.flush().await.unwrap();
    let received = server.received();
    assert_eq!(received.len(), 1);
    assert_headers(&received[0]);
    assert_rfc3339_millis(received[0].json()["sentAt"].as_str().unwrap());
    assert_eq!(received[0].events().len(), 1);
    assert_event(&received[0].events()[0], message_id);
    assert_eq!(clickman.pending().unwrap(), 0);
}

fn assert_headers(received: &Received) {
    assert_eq!(
        received.header("authorization"),
        format!("Bearer {WRITE_KEY}")
    );
    assert_eq!(received.header("content-type"), "application/json");
    assert_eq!(received.header("content-encoding"), "gzip");
}

fn assert_event(event: &Value, message_id: Uuid) {
    assert_eq!(event["type"], "track");
    assert_eq!(event["messageId"], message_id.to_string());
    assert_eq!(event["event"], "export_completed");
    assert_eq!(event["externalId"], "user_42");
    assert_rfc3339_millis(event["timestamp"].as_str().unwrap());
    assert_eq!(event["properties"], json!({"format": "mp4"}));
    let library = json!({"name": "clickman-rust", "version": env!("CARGO_PKG_VERSION")});
    let context = json!({"os": {"name": "macOS", "version": "26.1"}, "library": library, "traits": {"plan": "pro"}});
    assert_eq!(event["context"], context);
}

#[tokio::test]
async fn a_503_keeps_the_events_and_a_202_after_a_restart_deletes_them() {
    let server = StubServer::start([answer(503)]).await;
    let dir = scratch();
    let clickman = open(config(&server.endpoint, &dir));
    clickman.track("kept", json!({})).unwrap();
    clickman.flush().await.unwrap();
    clickman.flush().await.unwrap();
    assert_eq!(
        (server.received().len(), clickman.pending().unwrap()),
        (1, 1)
    );
    drop(clickman);
    let clickman = open(config(&server.endpoint, &dir));
    clickman.flush().await.unwrap();
    let received = server.received();
    assert_eq!(received.len(), 2);
    assert_eq!(received[1].events(), received[0].events());
    assert_eq!(clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn a_retry_after_longer_than_the_backoff_holds_the_next_send() {
    let server = StubServer::start([Answer {
        status: 429,
        retry_after: Some("3600"),
    }])
    .await;
    let dir = scratch();
    let clickman = open(config(&server.endpoint, &dir));
    clickman.track("throttled", json!({})).unwrap();
    clickman.flush().await.unwrap();
    tokio::time::sleep(PAST_THE_FIRST_BACKOFF).await;
    clickman.flush().await.unwrap();
    assert_eq!(server.received().len(), 1);
    assert_eq!(clickman.pending().unwrap(), 1);
}

#[tokio::test]
async fn send_due_sends_once_flush_at_events_wait() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let clickman = open(Config {
        flush_at: 3,
        ..config(&server.endpoint, &dir)
    });
    clickman.track("first", json!({})).unwrap();
    clickman.track("second", json!({})).unwrap();
    clickman.send_due().await.unwrap();
    assert!(server.received().is_empty());
    clickman.track("third", json!({})).unwrap();
    clickman.send_due().await.unwrap();
    assert_eq!(server.event_names(), ["first", "second", "third"]);
}

#[tokio::test]
async fn send_due_sends_the_oldest_once_it_has_waited_flush_interval() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let flush_interval = Duration::from_millis(100);
    let clickman = open(Config {
        flush_interval,
        ..config(&server.endpoint, &dir)
    });
    clickman.track("waiting", json!({})).unwrap();
    clickman.send_due().await.unwrap();
    assert!(server.received().is_empty());
    tokio::time::sleep(flush_interval).await;
    clickman.send_due().await.unwrap();
    assert_eq!(server.event_names(), ["waiting"]);
}

#[tokio::test]
async fn a_flush_splits_the_queue_into_batches() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let clickman = open(Config {
        max_batch_events: 2,
        ..config(&server.endpoint, &dir)
    });
    for index in 0..5 {
        clickman
            .track(&format!("event_{index}"), json!({}))
            .unwrap();
    }
    clickman.flush().await.unwrap();
    let sizes: Vec<usize> = server
        .received()
        .iter()
        .map(|received| received.events().len())
        .collect();
    assert_eq!(sizes, [2, 2, 1]);
    assert_eq!(clickman.pending().unwrap(), 0);
}
