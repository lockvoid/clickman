use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use flate2::Compression;
use flate2::write::GzEncoder;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::{Config, Error};

pub const ANONYMOUS: &str = "*";
const MAX_EVENT_CHARS: usize = 200;
const MAX_EXTERNAL_ID_CHARS: usize = 256;
const MAX_VERSION_CHARS: usize = 64;
const JITTER: f64 = 0.2;

const SCHEMA: &str = "
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS events (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at INTEGER NOT NULL,
      body TEXT NOT NULL,
      batch_id INTEGER
    );
    CREATE INDEX IF NOT EXISTS events_batch ON events (batch_id);
    CREATE TABLE IF NOT EXISTS state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
";

/// A batch handed to the platform to send: gzipped JSON per docs/PROTOCOL.md.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub id: u64,
    pub events: usize,
    pub body: Vec<u8>,
}

/// The device queue. Every call is one SQLite transaction behind one lock, so
/// the platform may call from any thread and a crash loses nothing committed.
pub struct Client {
    connection: Mutex<Connection>,
    config: Config,
}

impl Client {
    pub fn open(path: impl AsRef<Path>, config: Config) -> Result<Self, Error> {
        config.validate()?;
        let connection = Connection::open(path)?;
        connection.execute_batch(SCHEMA)?;

        Ok(Self {
            connection: Mutex::new(connection),
            config,
        })
    }

    pub fn identify(&self, external_id: &str) -> Result<(), Error> {
        if !valid_text(external_id, MAX_EXTERNAL_ID_CHARS) {
            return Err(Error::InvalidExternalId);
        }
        self.write(|transaction| set_state(transaction, "external_id", external_id))
    }

    /// Makes later events anonymous and forgets the traits, e.g. after signing out.
    pub fn reset(&self) -> Result<(), Error> {
        self.write(|transaction| {
            set_state(transaction, "external_id", ANONYMOUS)?;
            delete_state(transaction, "traits")
        })
    }

    pub fn external_id(&self) -> Result<String, Error> {
        self.write(|transaction| {
            Ok(state(transaction, "external_id")?.unwrap_or_else(|| ANONYMOUS.to_owned()))
        })
    }

    /// The context stamped on every event tracked from now on.
    pub fn set_context(&self, context: Value) -> Result<(), Error> {
        if !context.is_object() {
            return Err(Error::InvalidContext);
        }
        self.write(|transaction| set_state(transaction, "context", &context.to_string()))
    }

    /// Merges traits into `context.traits` of events tracked from now on; a
    /// null value removes a trait.
    pub fn set_traits(&self, traits: Value) -> Result<(), Error> {
        let Value::Object(changes) = traits else {
            return Err(Error::InvalidTraits);
        };

        self.write(|transaction| {
            let mut merged = object_state(transaction, "traits")?;
            for (key, value) in changes {
                if value.is_null() {
                    merged.remove(&key);
                } else {
                    merged.insert(key, value);
                }
            }

            if merged.is_empty() {
                delete_state(transaction, "traits")
            } else {
                set_state(transaction, "traits", &Value::Object(merged).to_string())
            }
        })
    }

    pub fn track(
        &self,
        event: &str,
        properties: Option<Value>,
        timestamp: Option<OffsetDateTime>,
        now: OffsetDateTime,
    ) -> Result<Uuid, Error> {
        if !valid_text(event, MAX_EVENT_CHARS) {
            return Err(Error::InvalidEvent(format!(
                "an event name is 1 to {MAX_EVENT_CHARS} characters without control characters"
            )));
        }
        let properties = match properties {
            None | Some(Value::Null) => Value::Object(Map::new()),
            Some(object @ Value::Object(_)) => object,
            Some(_) => return Err(Error::InvalidProperties),
        };

        self.write(|transaction| {
            self.insert(
                transaction,
                event,
                properties,
                timestamp.unwrap_or(now),
                now,
            )
        })
    }

    /// Records a launch of the app: `app_installed` on the first launch,
    /// `app_updated` on the first launch of a new version or build, then
    /// `app_opened`.
    pub fn app_launched(
        &self,
        version: &str,
        build: &str,
        now: OffsetDateTime,
    ) -> Result<(), Error> {
        if !valid_text(version, MAX_VERSION_CHARS) || !valid_text(build, MAX_VERSION_CHARS) {
            return Err(Error::InvalidVersion);
        }

        self.write(|transaction| {
            let previous_version = state(transaction, "app_version")?;
            let previous_build = state(transaction, "app_build")?;

            match (previous_version, previous_build) {
                (Some(previous_version), Some(previous_build)) => {
                    if previous_version != version || previous_build != build {
                        let properties = json!({
                            "version": version,
                            "build": build,
                            "previous_version": previous_version,
                            "previous_build": previous_build,
                        });
                        self.insert(transaction, "app_updated", properties, now, now)?;
                    }
                }
                _ => {
                    let properties = json!({ "version": version, "build": build });
                    self.insert(transaction, "app_installed", properties, now, now)?;
                }
            }

            set_state(transaction, "app_version", version)?;
            set_state(transaction, "app_build", build)?;
            self.insert(
                transaction,
                "app_opened",
                json!({ "from_background": false }),
                now,
                now,
            )?;
            Ok(())
        })
    }

    /// The next batch to send, or `None` when nothing is due: the queue is
    /// empty, a batch is still in flight, a retry is waiting out its delay, or —
    /// unless `force` — too few events have waited too little.
    pub fn take_batch(&self, now: OffsetDateTime, force: bool) -> Result<Option<Batch>, Error> {
        let config = &self.config;
        let now_ms = millis(now);

        let taken = self.write(|transaction| {
            transaction.execute(
                "DELETE FROM events WHERE created_at < ?1",
                params![now_ms.saturating_sub(duration_millis(config.max_age))],
            )?;

            if let Some(leased) = number_state(transaction, "lease_batch_id")? {
                if now_ms < number_state(transaction, "lease_until")?.unwrap_or(0) {
                    return Ok(None);
                }
                release(transaction, leased)?;
            }

            if now_ms < number_state(transaction, "next_attempt_at")?.unwrap_or(i64::MIN) {
                return Ok(None);
            }

            let (waiting, oldest): (i64, Option<i64>) = transaction.query_row(
                "SELECT count(*), min(created_at) FROM events WHERE batch_id IS NULL",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let Some(oldest) = oldest else {
                return Ok(None);
            };
            let due = force
                || waiting as usize >= config.flush_at
                || now_ms - oldest >= duration_millis(config.flush_interval);
            if !due {
                return Ok(None);
            }

            let mut statement = transaction.prepare(
                "SELECT seq, body FROM events WHERE batch_id IS NULL ORDER BY seq LIMIT ?1",
            )?;
            let rows = statement
                .query_map(params![config.max_batch_events as i64], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            drop(statement);

            let head = format!(r#"{{"sentAt":"{}","batch":["#, rfc3339(now));
            let mut json = head.clone();
            let mut seqs = Vec::new();
            for (seq, body) in rows {
                let separator = usize::from(!seqs.is_empty());
                if !seqs.is_empty()
                    && json.len() + separator + body.len() + 2 > config.max_batch_bytes
                {
                    break;
                }
                if !seqs.is_empty() {
                    json.push(',');
                }
                json.push_str(&body);
                seqs.push(seq);
            }
            json.push_str("]}");

            let batch_id = number_state(transaction, "next_batch_id")?.unwrap_or(1);
            set_state(transaction, "next_batch_id", &(batch_id + 1).to_string())?;
            set_state(transaction, "lease_batch_id", &batch_id.to_string())?;
            set_state(
                transaction,
                "lease_until",
                &(now_ms + duration_millis(config.lease)).to_string(),
            )?;
            for seq in &seqs {
                transaction.execute(
                    "UPDATE events SET batch_id = ?1 WHERE seq = ?2",
                    params![batch_id, seq],
                )?;
            }

            Ok(Some((batch_id as u64, seqs.len(), json)))
        })?;

        taken
            .map(|(id, events, json)| {
                Ok(Batch {
                    id,
                    events,
                    body: gzip(json.as_bytes())?,
                })
            })
            .transpose()
    }

    /// Records how sending a batch ended: `status` is the HTTP status, or 0 when
    /// no response came back. Delivered and permanently refused batches leave
    /// the queue; anything else returns to it behind a growing delay.
    pub fn complete(
        &self,
        batch_id: u64,
        status: u16,
        retry_after: Option<Duration>,
        now: OffsetDateTime,
    ) -> Result<(), Error> {
        let config = &self.config;

        self.write(|transaction| {
            let batch_id = batch_id as i64;
            if number_state(transaction, "lease_batch_id")? != Some(batch_id) {
                return Ok(());
            }
            delete_state(transaction, "lease_batch_id")?;
            delete_state(transaction, "lease_until")?;

            if finished(status) {
                transaction.execute("DELETE FROM events WHERE batch_id = ?1", params![batch_id])?;
                delete_state(transaction, "attempts")?;
                delete_state(transaction, "next_attempt_at")?;
                return Ok(());
            }

            release(transaction, batch_id)?;
            let attempts = number_state(transaction, "attempts")?.unwrap_or(0) + 1;
            let delay = backoff(config, attempts).max(retry_after.unwrap_or_default());
            set_state(transaction, "attempts", &attempts.to_string())?;
            set_state(
                transaction,
                "next_attempt_at",
                &(millis(now) + duration_millis(delay)).to_string(),
            )?;
            Ok(())
        })
    }

    /// Events on the device, in flight or waiting.
    pub fn pending(&self) -> Result<usize, Error> {
        self.write(|transaction| {
            let count: i64 =
                transaction.query_row("SELECT count(*) FROM events", [], |row| row.get(0))?;
            Ok(count as usize)
        })
    }

    fn insert(
        &self,
        transaction: &Transaction,
        event: &str,
        properties: Value,
        timestamp: OffsetDateTime,
        now: OffsetDateTime,
    ) -> Result<Uuid, Error> {
        let message_id = Uuid::now_v7();
        let mut context = object_state(transaction, "context")?;
        let traits = object_state(transaction, "traits")?;
        if !traits.is_empty() {
            context.insert("traits".to_owned(), Value::Object(traits));
        }
        let external_id =
            state(transaction, "external_id")?.unwrap_or_else(|| ANONYMOUS.to_owned());

        let body = json!({
            "type": "track",
            "messageId": message_id.to_string(),
            "event": event,
            "externalId": external_id,
            "timestamp": rfc3339(timestamp),
            "properties": properties,
            "context": context,
        });
        transaction.execute(
            "INSERT INTO events (created_at, body) VALUES (?1, ?2)",
            params![millis(now), body.to_string()],
        )?;
        transaction.execute(
            "DELETE FROM events WHERE seq IN
               (SELECT seq FROM events ORDER BY seq DESC LIMIT -1 OFFSET ?1)",
            params![self.config.max_queue as i64],
        )?;

        Ok(message_id)
    }

    fn write<T>(&self, work: impl FnOnce(&Transaction) -> Result<T, Error>) -> Result<T, Error> {
        let mut connection = self
            .connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let transaction = connection.transaction()?;
        let result = work(&transaction)?;
        transaction.commit()?;
        Ok(result)
    }
}

/// Delivered, or refused for good (docs/PROTOCOL.md): the batch leaves the queue.
fn finished(status: u16) -> bool {
    (200..300).contains(&status) || matches!(status, 400 | 413 | 415)
}

fn backoff(config: &Config, attempts: i64) -> Duration {
    let exponent = u32::try_from(attempts.saturating_sub(1))
        .unwrap_or(u32::MAX)
        .min(30);
    let base = config
        .backoff_base
        .saturating_mul(2u32.saturating_pow(exponent))
        .min(config.backoff_max);
    let jitter = 1.0 + JITTER * (fastrand::f64() * 2.0 - 1.0);
    base.mul_f64(jitter)
}

fn release(transaction: &Transaction, batch_id: i64) -> Result<(), Error> {
    transaction.execute(
        "UPDATE events SET batch_id = NULL WHERE batch_id = ?1",
        params![batch_id],
    )?;
    delete_state(transaction, "lease_batch_id")?;
    delete_state(transaction, "lease_until")?;
    Ok(())
}

fn state(transaction: &Transaction, key: &str) -> Result<Option<String>, Error> {
    Ok(transaction
        .query_row(
            "SELECT value FROM state WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()?)
}

fn object_state(transaction: &Transaction, key: &str) -> Result<Map<String, Value>, Error> {
    Ok(state(transaction, key)?
        .and_then(|json| serde_json::from_str::<Map<String, Value>>(&json).ok())
        .unwrap_or_default())
}

fn number_state(transaction: &Transaction, key: &str) -> Result<Option<i64>, Error> {
    Ok(state(transaction, key)?.and_then(|value| value.parse().ok()))
}

fn set_state(transaction: &Transaction, key: &str, value: &str) -> Result<(), Error> {
    transaction.execute(
        "INSERT INTO state (key, value) VALUES (?1, ?2)
         ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

fn delete_state(transaction: &Transaction, key: &str) -> Result<(), Error> {
    transaction.execute("DELETE FROM state WHERE key = ?1", params![key])?;
    Ok(())
}

fn valid_text(text: &str, max_chars: usize) -> bool {
    let chars = text.chars().count();
    chars > 0 && chars <= max_chars && !text.chars().any(char::is_control)
}

fn rfc3339(time: OffsetDateTime) -> String {
    time.format(&Rfc3339)
        .expect("a UTC time formats as RFC 3339")
}

fn millis(time: OffsetDateTime) -> i64 {
    (time.unix_timestamp_nanos() / 1_000_000) as i64
}

fn duration_millis(duration: Duration) -> i64 {
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

fn gzip(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    let mut encoder = GzEncoder::new(Vec::with_capacity(bytes.len() / 4), Compression::default());
    encoder.write_all(bytes)?;
    Ok(encoder.finish()?)
}
