use std::time::Duration;

use serde_json::Value;

use crate::Error;

/// How the queue decides when a batch is due and how it retries; the defaults
/// are the client rules of docs/PROTOCOL.md.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// A batch is due once this many events are waiting.
    pub flush_at: usize,
    /// A batch is due once the oldest waiting event is this old.
    pub flush_interval: Duration,
    /// The most events kept on the device; the oldest go first.
    pub max_queue: usize,
    /// Events older than this are dropped unsent.
    pub max_age: Duration,
    /// The most events in one batch.
    pub max_batch_events: usize,
    /// The most bytes of JSON in one batch, before compression.
    pub max_batch_bytes: usize,
    /// How long a batch handed to the platform stays reserved for it.
    pub lease: Duration,
    /// The first retry delay, doubled per failure up to `backoff_max`.
    pub backoff_base: Duration,
    pub backoff_max: Duration,
}

pub const MAX_BATCH_EVENTS: usize = 500;
pub const MAX_BATCH_BYTES: usize = 1_000_000;

impl Default for Config {
    fn default() -> Self {
        Self {
            flush_at: 20,
            flush_interval: Duration::from_secs(30),
            max_queue: 10_000,
            max_age: Duration::from_secs(30 * 24 * 60 * 60),
            max_batch_events: 100,
            max_batch_bytes: 900_000,
            lease: Duration::from_secs(60),
            backoff_base: Duration::from_secs(5),
            backoff_max: Duration::from_secs(600),
        }
    }
}

impl Config {
    /// Reads the camelCase JSON the platform wrappers pass, durations in
    /// milliseconds; absent keys keep their defaults, unknown keys are refused.
    pub fn from_json(json: &str) -> Result<Self, Error> {
        let value: Value = serde_json::from_str(json)
            .map_err(|error| Error::InvalidConfig(format!("the config is not JSON: {error}")))?;
        let object = value
            .as_object()
            .ok_or_else(|| Error::InvalidConfig("the config is not a JSON object".into()))?;

        let mut config = Self::default();
        for (key, value) in object {
            let number = value
                .as_u64()
                .filter(|number| *number > 0)
                .ok_or_else(|| Error::InvalidConfig(format!("{key} must be a positive integer")))?;
            let count = usize::try_from(number)
                .map_err(|_| Error::InvalidConfig(format!("{key} is too large")))?;
            let millis = Duration::from_millis(number);

            match key.as_str() {
                "flushAt" => config.flush_at = count,
                "flushIntervalMs" => config.flush_interval = millis,
                "maxQueue" => config.max_queue = count,
                "maxAgeMs" => config.max_age = millis,
                "maxBatchEvents" => config.max_batch_events = count,
                "maxBatchBytes" => config.max_batch_bytes = count,
                "leaseMs" => config.lease = millis,
                "backoffBaseMs" => config.backoff_base = millis,
                "backoffMaxMs" => config.backoff_max = millis,
                unknown => {
                    return Err(Error::InvalidConfig(format!(
                        "unknown config key {unknown}"
                    )));
                }
            }
        }

        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), Error> {
        if self.max_batch_events > MAX_BATCH_EVENTS {
            return Err(Error::InvalidConfig(format!(
                "maxBatchEvents is at most {MAX_BATCH_EVENTS}"
            )));
        }
        if self.max_batch_bytes > MAX_BATCH_BYTES {
            return Err(Error::InvalidConfig(format!(
                "maxBatchBytes is at most {MAX_BATCH_BYTES}"
            )));
        }
        if self.backoff_max < self.backoff_base {
            return Err(Error::InvalidConfig(
                "backoffMaxMs must be at least backoffBaseMs".into(),
            ));
        }
        Ok(())
    }
}
