use std::path::PathBuf;
use std::time::Duration;

use crate::Config;

#[test]
fn new_takes_the_protocol_defaults() {
    let config = Config::new(
        "https://ingest.example",
        "wk_ios",
        "/tmp/clickman/queue.sqlite",
    );
    let expected = Config {
        endpoint: "https://ingest.example".to_owned(),
        write_key: "wk_ios".to_owned(),
        path: PathBuf::from("/tmp/clickman/queue.sqlite"),
        flush_at: 20,
        flush_interval: Duration::from_secs(30),
        max_queue: 10_000,
        max_age: Duration::from_secs(30 * 24 * 60 * 60),
        max_batch_events: 100,
        max_batch_bytes: 900_000,
    };
    assert_eq!(config, expected);
}
