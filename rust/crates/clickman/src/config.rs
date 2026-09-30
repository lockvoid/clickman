use std::path::PathBuf;
use std::time::Duration;

/// Where events go and when; `Config::new` takes the defaults of docs/PROTOCOL.md.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// The ingest server; batches go to `{endpoint}/v1/batch`.
    pub endpoint: String,
    /// The source's write key.
    pub write_key: String,
    /// The queue's SQLite file; missing directories are created.
    pub path: PathBuf,
    /// A batch is due once this many events wait.
    pub flush_at: usize,
    /// A batch is due once the oldest event has waited this long.
    pub flush_interval: Duration,
    /// The most events kept: the newest drops the oldest beyond it.
    pub max_queue: usize,
    /// Events older than this are deleted unsent.
    pub max_age: Duration,
    /// The most events in one batch.
    pub max_batch_events: usize,
    /// The most bytes in one batch, counted over the bodies joined by commas.
    pub max_batch_bytes: usize,
}

impl Config {
    pub fn new(
        endpoint: impl Into<String>,
        write_key: impl Into<String>,
        path: impl Into<PathBuf>,
    ) -> Self {
        Self {
            endpoint: endpoint.into(),
            write_key: write_key.into(),
            path: path.into(),
            flush_at: 20,
            flush_interval: Duration::from_secs(30),
            max_queue: 10_000,
            max_age: Duration::from_secs(30 * 24 * 60 * 60),
            max_batch_events: 100,
            max_batch_bytes: 900_000,
        }
    }
}
