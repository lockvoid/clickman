//! The ClickMan ingest server: `POST /v1/batch` per docs/PROTOCOL.md, written
//! straight into `clickman_events` — PostgreSQL or SQLite — for the Rails engine
//! to rotate and report on.

mod app;
mod body;
mod database;
mod limiter;
mod schema;
mod settings;

pub use app::{AppState, router};
pub use body::{MAX_DECOMPRESSED_BYTES, MAX_WIRE_BYTES};
pub use database::Database;
pub use schema::verify_schema;
pub use settings::{RateLimit, Settings, SettingsCell, digest};
