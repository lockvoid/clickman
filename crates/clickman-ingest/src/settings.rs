use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::Database;
use anyhow::Context;
use clickman_protocol::{DEFAULT_FRAGMENTS, Limits, Sanitizer};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use time::Duration;

/// The hex SHA-256 of a write key, as the Rails engine publishes it.
pub fn digest(key: &str) -> String {
    Sha256::digest(key.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimit {
    pub per_second: f64,
    pub burst: f64,
}

impl Default for RateLimit {
    fn default() -> Self {
        Self {
            per_second: 20.0,
            burst: 100.0,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Published {
    #[serde(default)]
    write_keys: Vec<PublishedKey>,
    #[serde(default = "default_fragments")]
    fragments: Vec<String>,
    #[serde(default = "default_max_event_age_days")]
    max_event_age_days: i64,
    #[serde(default)]
    rate_limit: RateLimit,
}

#[derive(Debug, Deserialize)]
struct PublishedKey {
    name: String,
    digest: String,
}

fn default_fragments() -> Vec<String> {
    DEFAULT_FRAGMENTS
        .iter()
        .map(|fragment| (*fragment).to_owned())
        .collect()
}

fn default_max_event_age_days() -> i64 {
    90
}

/// What the ingest server enforces, as published by the Rails engine in
/// `clickman_settings` under the key `ingest`.
pub struct Settings {
    sources: HashMap<String, String>,
    pub sanitizer: Sanitizer,
    pub limits: Limits,
    pub rate_limit: RateLimit,
}

impl Settings {
    /// No write keys: every batch is refused until settings are published.
    pub fn empty() -> Self {
        Self {
            sources: HashMap::new(),
            sanitizer: Sanitizer::default(),
            limits: Limits::default(),
            rate_limit: RateLimit::default(),
        }
    }

    pub fn from_value(value: Value) -> anyhow::Result<Self> {
        let published: Published =
            serde_json::from_value(value).context("the published ingest settings are malformed")?;

        Ok(Self {
            sources: published
                .write_keys
                .into_iter()
                .map(|key| (key.digest.to_lowercase(), key.name))
                .collect(),
            sanitizer: Sanitizer::new(&published.fragments),
            limits: Limits {
                max_event_age: Duration::days(published.max_event_age_days),
                ..Limits::default()
            },
            rate_limit: published.rate_limit,
        })
    }

    /// The source a write key belongs to, if it is a known key.
    pub fn source_for(&self, write_key: &str) -> Option<&str> {
        self.sources.get(&digest(write_key)).map(String::as_str)
    }
}

/// The current settings, swapped whole on reload so a request always sees one
/// consistent snapshot.
#[derive(Clone)]
pub struct SettingsCell(Arc<RwLock<Arc<Settings>>>);

impl SettingsCell {
    pub fn new(settings: Settings) -> Self {
        Self(Arc::new(RwLock::new(Arc::new(settings))))
    }

    pub async fn load(database: &Database) -> anyhow::Result<Self> {
        Ok(Self::new(fetch(database).await?))
    }

    pub async fn reload(&self, database: &Database) -> anyhow::Result<()> {
        let settings = Arc::new(fetch(database).await?);
        *self
            .0
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = settings;
        Ok(())
    }

    pub fn current(&self) -> Arc<Settings> {
        self.0
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

async fn fetch(database: &Database) -> anyhow::Result<Settings> {
    match database
        .settings()
        .await
        .context("read clickman_settings")?
    {
        Some(value) => Settings::from_value(value),
        None => Ok(Settings::empty()),
    }
}
