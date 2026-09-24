//! The ClickMan device core: a durable queue of events on the device that
//! hands out gzipped batches for the platform to send (docs/PROTOCOL.md) and
//! decides when a batch is due and how failed sends are retried. Networking is
//! the platform's; the Swift and Kotlin wrappers call through `include/clickman.h`.

pub mod capi;
mod client;
mod config;

pub use client::{ANONYMOUS, Batch, Client};
pub use config::{Config, MAX_BATCH_BYTES, MAX_BATCH_EVENTS};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid event: {0}")]
    InvalidEvent(String),
    #[error("an external id is 1 to 256 characters without control characters")]
    InvalidExternalId,
    #[error("properties must be a JSON object")]
    InvalidProperties,
    #[error("the context must be a JSON object")]
    InvalidContext,
    #[error("traits must be a JSON object")]
    InvalidTraits,
    #[error("an app version and build are 1 to 64 characters without control characters")]
    InvalidVersion,
    #[error("invalid config: {0}")]
    InvalidConfig(String),
    #[error("storage: {0}")]
    Storage(#[from] rusqlite::Error),
    #[error("encoding: {0}")]
    Encoding(#[from] std::io::Error),
}

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
