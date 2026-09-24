//! The ClickMan wire protocol (docs/PROTOCOL.md): batch validation, flattening
//! of properties and context, and the sanitizer that keeps personal data out
//! of storage. Shared by the ingest server and the device core.

mod batch;
mod flatten;
mod sanitize;

pub use batch::{BatchError, Event, Limits, Normalized, Reason, Rejection, normalize};
pub use flatten::{MAX_DEPTH, MAX_STRING_CHARS, flatten};
pub use sanitize::{DEFAULT_FRAGMENTS, FILTERED, Sanitizer};

/// The protocol version this crate speaks, the `v1` of `POST /v1/batch`.
pub const PROTOCOL_VERSION: u32 = 1;
