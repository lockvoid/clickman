//! ClickMan for Rust applications, the Rust client of docs/PROTOCOL.md: `track`
//! stores each event in a SQLite queue, and `send_due`, called on the host's own
//! timer, sends what is due in gzipped batches through the host's `HttpClient`.

mod backoff;
mod batch;
mod client;
mod clock;
mod config;
mod context;
mod error;
mod event;
mod gzip;
mod identity;
mod launch;
mod outcome;
mod queue_schema;
mod sender;
mod store;
mod transport;

pub use client::ClickMan;
pub use config::Config;
pub use error::{Error, Result};
pub use transport::{BoxFuture, HttpClient, HttpResponse};

#[cfg(test)]
mod tests;
