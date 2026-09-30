mod support;

use std::time::Duration;

use clickman::Config;
use serde_json::json;

use support::{StubServer, config, open, scratch};

#[tokio::test]
async fn the_queue_keeps_the_newest_max_queue_events() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let clickman = open(Config {
        max_queue: 3,
        ..config(&server.endpoint, &dir)
    });
    for index in 0..5 {
        clickman
            .track(&format!("event_{index}"), json!({}))
            .unwrap();
    }
    assert_eq!(clickman.pending().unwrap(), 3);
    clickman.flush().await.unwrap();
    assert_eq!(server.event_names(), ["event_2", "event_3", "event_4"]);
}

#[tokio::test]
async fn events_older_than_max_age_are_deleted_unsent() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let max_age = Duration::from_millis(200);
    let clickman = open(Config {
        max_age,
        ..config(&server.endpoint, &dir)
    });
    clickman.track("expired", json!({})).unwrap();
    tokio::time::sleep(max_age + Duration::from_millis(100)).await;
    clickman.track("fresh", json!({})).unwrap();
    clickman.flush().await.unwrap();
    assert_eq!(server.event_names(), ["fresh"]);
    assert_eq!(clickman.pending().unwrap(), 0);
}
