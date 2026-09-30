use std::sync::Arc;
use std::time::Duration;

use parking_lot::Mutex;
use serde_json::json;
use tempfile::TempDir;
use tokio::sync::Notify;

use crate::ClickMan;
use crate::tests::support::{
    FakeClock, Harness, Posted, open_client, retry_after, scratch_config, status, stored_texts,
};
use crate::transport::{BoxFuture, HttpClient, HttpResponse};

fn posts(harness: &Harness) -> usize {
    harness.http.posted().len()
}

#[tokio::test]
async fn a_batch_is_gzipped_json_posted_to_v1_batch_with_the_write_key() {
    let harness = Harness::with(
        |config| config.endpoint = "https://ingest.test/".to_owned(),
        [],
    );
    harness.clickman.track("first", json!({})).unwrap();
    harness.clickman.track("second", json!({"n": 2})).unwrap();
    let bodies = stored_texts(&harness.config.path);
    harness.clickman.flush().await.unwrap();
    let posted = harness.http.posted();
    assert_eq!(posted.len(), 1);
    assert_eq!(posted[0].url, "https://ingest.test/v1/batch");
    let headers = [
        ("Authorization".to_owned(), "Bearer wk_test".to_owned()),
        ("Content-Type".to_owned(), "application/json".to_owned()),
        ("Content-Encoding".to_owned(), "gzip".to_owned()),
    ];
    assert_eq!(posted[0].headers, headers);
    let payload = format!(
        r#"{{"sentAt":"2026-09-30T12:00:00.123Z","batch":[{},{}]}}"#,
        bodies[0], bodies[1]
    );
    assert_eq!(posted[0].payload(), payload);
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn sent_at_is_the_clock_when_the_batch_goes() {
    let harness = Harness::new();
    harness.clickman.track("event", json!({})).unwrap();
    harness.clock.advance(Duration::from_secs(2));
    harness.clickman.flush().await.unwrap();
    assert!(
        harness.http.posted()[0]
            .payload()
            .starts_with(r#"{"sentAt":"2026-09-30T12:00:02.123Z","#)
    );
}

#[tokio::test]
async fn a_flush_sends_batch_after_batch_until_the_queue_is_empty() {
    let harness = Harness::with(|config| config.max_batch_events = 2, []);
    for index in 0..5 {
        harness
            .clickman
            .track(&format!("event_{index}"), json!({}))
            .unwrap();
    }
    harness.clickman.flush().await.unwrap();
    let sizes: Vec<usize> = harness
        .http
        .posted()
        .iter()
        .map(|posted| posted.events().len())
        .collect();
    assert_eq!(sizes, [2, 2, 1]);
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn send_due_sends_what_is_due_and_leaves_the_rest() {
    let harness = Harness::with(
        |config| (config.flush_at, config.max_batch_events) = (2, 2),
        [],
    );
    harness.clickman.track("first", json!({})).unwrap();
    harness.clickman.send_due().await.unwrap();
    assert_eq!(posts(&harness), 0);
    harness.clickman.track("second", json!({})).unwrap();
    harness.clickman.track("third", json!({})).unwrap();
    harness.clickman.send_due().await.unwrap();
    assert_eq!(harness.http.posted()[0].event_names(), ["first", "second"]);
    assert_eq!(posts(&harness), 1);
    assert_eq!(harness.clickman.pending().unwrap(), 1);
}

#[tokio::test]
async fn a_failed_send_ends_the_drain() {
    let harness = Harness::with(|config| config.max_batch_events = 1, [Ok(status(503))]);
    harness.clickman.track("first", json!({})).unwrap();
    harness.clickman.track("second", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(&harness), 1);
    assert_eq!(harness.clickman.pending().unwrap(), 2);
}

#[tokio::test]
async fn a_refused_batch_leaves_the_queue_and_the_drain_goes_on() {
    let harness = Harness::with(|config| config.max_batch_events = 1, [Ok(status(400))]);
    harness.clickman.track("first", json!({})).unwrap();
    harness.clickman.track("second", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(&harness), 2);
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn after_a_failure_nothing_is_sent_until_the_delay_passes_forced_or_not() {
    let harness = Harness::with(|config| config.flush_at = 1, [Ok(status(503))]);
    harness.clickman.track("event", json!({})).unwrap();
    harness.clickman.send_due().await.unwrap();
    harness.clock.advance(Duration::from_millis(4_999));
    harness.clickman.send_due().await.unwrap();
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(&harness), 1);
    harness.clock.advance(Duration::from_millis(1));
    harness.clickman.send_due().await.unwrap();
    assert_eq!(posts(&harness), 2);
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn consecutive_failures_double_the_delay_and_a_delivery_resets_it() {
    let answers = [
        Ok(status(503)),
        Ok(status(503)),
        Ok(status(202)),
        Ok(status(503)),
    ];
    let harness = Harness::with(|_| {}, answers);
    harness.clickman.track("first", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    harness.clock.advance(Duration::from_secs(5));
    harness.clickman.flush().await.unwrap();
    assert_delay(&harness, Duration::from_secs(10)).await;
    assert_eq!(harness.clickman.pending().unwrap(), 0);
    harness.clickman.track("second", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_delay(&harness, Duration::from_secs(5)).await;
    assert_eq!(posts(&harness), 5);
}

/// Nothing goes a millisecond before `delay` has passed, and the next attempt goes at `delay`.
async fn assert_delay(harness: &Harness, delay: Duration) {
    let before = posts(harness);
    harness.clock.advance(delay - Duration::from_millis(1));
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(harness), before, "sent before {delay:?}");
    harness.clock.advance(Duration::from_millis(1));
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(harness), before + 1, "not sent at {delay:?}");
}

#[tokio::test]
async fn a_longer_retry_after_wins_over_the_backoff() {
    let harness = Harness::with(|_| {}, [Ok(retry_after(429, "30"))]);
    harness.clickman.track("event", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_delay(&harness, Duration::from_secs(30)).await;
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn a_shorter_retry_after_loses_to_the_backoff() {
    let harness = Harness::with(|_| {}, [Ok(retry_after(503, "1"))]);
    harness.clickman.track("event", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_delay(&harness, Duration::from_secs(5)).await;
}

#[tokio::test]
async fn no_response_is_a_retry() {
    let harness = Harness::with(|_| {}, [Err("connection refused".to_owned())]);
    harness.clickman.track("event", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    assert_eq!(harness.clickman.pending().unwrap(), 1);
    assert_delay(&harness, Duration::from_secs(5)).await;
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn a_restarted_client_sends_at_once() {
    let harness = Harness::with(|_| {}, [Ok(status(503))]);
    harness.clickman.track("event", json!({})).unwrap();
    harness.clickman.flush().await.unwrap();
    let harness = harness.reopen([]);
    harness.clickman.flush().await.unwrap();
    assert_eq!(posts(&harness), 1);
    assert_eq!(harness.clickman.pending().unwrap(), 0);
}

/// Holds each request until the test lets it through.
#[derive(Clone, Default)]
struct HeldHttp {
    arrived: Arc<Notify>,
    released: Arc<Notify>,
    posted: Arc<Mutex<Vec<Posted>>>,
}

impl HeldHttp {
    fn posted(&self) -> Vec<Posted> {
        self.posted.lock().clone()
    }
}

impl HttpClient for HeldHttp {
    fn post<'a>(
        &'a self,
        url: &'a str,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> BoxFuture<'a, Result<HttpResponse, String>> {
        self.posted.lock().push(Posted {
            url: url.to_owned(),
            headers,
            body,
        });
        Box::pin(async move {
            self.arrived.notify_one();
            self.released.notified().await;
            Ok(status(202))
        })
    }
}

fn held_client(http: &HeldHttp) -> (TempDir, Arc<ClickMan>) {
    let dir = tempfile::tempdir().unwrap();
    let clickman = open_client(scratch_config(&dir), http.clone(), &FakeClock::new());
    (dir, Arc::new(clickman))
}

/// Fails the test instead of hanging it when `future` never finishes.
async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(5), future)
        .await
        .expect("still waiting after 5 s")
}

fn spawn_flush(clickman: &Arc<ClickMan>) -> tokio::task::JoinHandle<crate::Result<()>> {
    let clickman = clickman.clone();
    tokio::spawn(async move { clickman.flush().await })
}

#[tokio::test]
async fn one_batch_is_in_flight_at_a_time() {
    let http = HeldHttp::default();
    let (_dir, clickman) = held_client(&http);
    clickman.track("event", json!({})).unwrap();
    let first = spawn_flush(&clickman);
    within(http.arrived.notified()).await;
    within(clickman.flush()).await.unwrap();
    assert_eq!(http.posted().len(), 1);
    http.released.notify_one();
    within(first).await.unwrap().unwrap();
    assert_eq!(clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn a_cancelled_send_lets_the_next_one_go() {
    let http = HeldHttp::default();
    let (_dir, clickman) = held_client(&http);
    clickman.track("event", json!({})).unwrap();
    let cancelled = tokio::time::timeout(Duration::from_millis(50), clickman.flush()).await;
    assert!(cancelled.is_err());
    assert_eq!(clickman.pending().unwrap(), 1);
    http.released.notify_one();
    within(clickman.flush()).await.unwrap();
    assert_eq!(http.posted().len(), 2);
    assert_eq!(clickman.pending().unwrap(), 0);
}

#[tokio::test]
async fn events_tracked_during_a_send_wait_for_the_next_batch() {
    let http = HeldHttp::default();
    let (_dir, clickman) = held_client(&http);
    clickman.track("first", json!({})).unwrap();
    let flush = spawn_flush(&clickman);
    within(http.arrived.notified()).await;
    clickman.track("second", json!({})).unwrap();
    http.released.notify_one();
    within(http.arrived.notified()).await;
    http.released.notify_one();
    within(flush).await.unwrap().unwrap();
    let batches: Vec<Vec<String>> = http.posted().iter().map(Posted::event_names).collect();
    assert_eq!(batches, [["first"], ["second"]]);
    assert_eq!(clickman.pending().unwrap(), 0);
}
