use rusqlite::{Transaction, params};
use serde_json::{Map, Value, json};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::clock::{rfc3339_millis, unix_millis};
use crate::context;
use crate::error::{Error, Result};
use crate::identity;
use crate::store::sql_count;

pub(crate) const MAX_EVENT_CHARS: usize = 200;

/// Whether `text` is 1 to `max_chars` Unicode scalar values without control characters (events.json).
pub(crate) fn is_valid_text(text: &str, max_chars: usize) -> bool {
    (1..=max_chars).contains(&text.chars().count()) && !text.chars().any(char::is_control)
}

/// Stores events in one transaction, all stamped with one time and context.
pub(crate) struct Recorder<'a> {
    pub(crate) transaction: &'a Transaction<'a>,
    pub(crate) context: &'a Map<String, Value>,
    pub(crate) now: OffsetDateTime,
    pub(crate) max_queue: usize,
}

impl Recorder<'_> {
    /// Stores an event for the current actor, then drops the oldest beyond `max_queue`.
    pub(crate) fn record(&self, event: &str, properties: Map<String, Value>) -> Result<Uuid> {
        if !is_valid_text(event, MAX_EVENT_CHARS) {
            return Err(Error::InvalidEvent);
        }
        let message_id = Uuid::now_v7();
        let body = self.body(message_id, event, properties)?;
        self.insert(&body)?;
        self.trim()?;
        Ok(message_id)
    }

    fn body(&self, message_id: Uuid, event: &str, properties: Map<String, Value>) -> Result<Value> {
        let actor = identity::actor(self.transaction)?;
        Ok(json!({
            "type": "track",
            "messageId": message_id.to_string(),
            "event": event,
            "externalId": actor.external_id,
            "timestamp": rfc3339_millis(self.now),
            "properties": properties,
            "context": context::with_traits(self.context, actor.traits),
        }))
    }

    fn insert(&self, body: &Value) -> Result<()> {
        let sql = "INSERT INTO events (created_at, body) VALUES (?1, ?2)";
        self.transaction
            .execute(sql, params![unix_millis(self.now), body.to_string()])?;
        Ok(())
    }

    fn trim(&self) -> Result<()> {
        self.transaction.execute(
            "DELETE FROM events WHERE seq IN
               (SELECT seq FROM events ORDER BY seq DESC LIMIT -1 OFFSET ?1)",
            [sql_count(self.max_queue)],
        )?;
        Ok(())
    }
}
