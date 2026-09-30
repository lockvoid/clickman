use std::path::PathBuf;

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("an event name is 1 to 200 characters without control characters")]
    InvalidEvent,
    #[error("an external id is 1 to 256 characters without control characters")]
    InvalidExternalId,
    #[error("properties must be a JSON object")]
    InvalidProperties,
    #[error("traits must be a JSON object")]
    InvalidTraits,
    #[error("the context must be a JSON object")]
    InvalidContext,
    #[error("the store is format {format}, written by a newer ClickMan")]
    NewerStore { format: i64 },
    #[error("the store is format {format}, which no ClickMan writes")]
    UnknownStore { format: i64 },
    #[error("could not create the store directory {}: {source}", path.display())]
    StoreDirectory {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("the stored traits are not a JSON object: {0}")]
    StoredTraits(#[source] serde_json::Error),
    #[error("could not compress a batch: {0}")]
    Compression(#[source] std::io::Error),
    #[error("storage: {0}")]
    Storage(#[from] rusqlite::Error),
}
