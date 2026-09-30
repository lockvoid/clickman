use rusqlite::{Connection, Transaction};

use crate::clock::millis;
use crate::config::Config;
use crate::error::Result;
use crate::store::sql_count;

/// The oldest waiting events, taken to send together; `last_seq` is the newest of them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Batch {
    pub(crate) last_seq: i64,
    pub(crate) bodies: Vec<String>,
}

/// Whether a batch goes only when due, or whenever anything waits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Urgency {
    Due,
    Forced,
}

impl Batch {
    /// `{"sentAt": …, "batch": [bodies]}`, the bodies verbatim.
    pub(crate) fn payload(&self, sent_at: &str) -> String {
        format!(
            r#"{{"sentAt":"{sent_at}","batch":[{}]}}"#,
            self.bodies.join(",")
        )
    }

    fn cut(mut rows: Vec<(i64, String)>, config: &Config) -> Option<Self> {
        let bodies = rows.iter().map(|(_, body)| body.as_str());
        let count = taken(bodies, config.max_batch_events, config.max_batch_bytes);
        rows.truncate(count);
        let last_seq = rows.last()?.0;
        let bodies = rows.into_iter().map(|(_, body)| body).collect();
        Some(Self { last_seq, bodies })
    }
}

/// The next batch, or `None` when nothing is due; events older than `max_age`
/// are deleted unsent first. `now` is in milliseconds since the Unix epoch.
pub(crate) fn take(
    transaction: &Transaction,
    config: &Config,
    now: i64,
    urgency: Urgency,
) -> Result<Option<Batch>> {
    purge(transaction, now.saturating_sub(millis(config.max_age)))?;
    if !is_due(transaction, config, now, urgency)? {
        return Ok(None);
    }
    let rows = oldest(transaction, config.max_batch_events)?;
    Ok(Batch::cut(rows, config))
}

/// How many of the oldest `bodies` one batch takes: at most `max_events`, while
/// they stay within `max_bytes` UTF-8 bytes joined by commas; the oldest goes
/// even alone over the limit (batches.json).
pub(crate) fn taken<'a>(
    bodies: impl IntoIterator<Item = &'a str>,
    max_events: usize,
    max_bytes: usize,
) -> usize {
    let mut joined = 0;
    bodies
        .into_iter()
        .take(max_events)
        .enumerate()
        .take_while(|(index, body)| {
            joined += body.len() + usize::from(*index > 0);
            *index == 0 || joined <= max_bytes
        })
        .count()
}

/// Deletes a delivered or refused batch; events tracked since keep their place.
pub(crate) fn remove(transaction: &Transaction, batch: &Batch) -> Result<()> {
    transaction.execute("DELETE FROM events WHERE seq < ?1", [batch.last_seq])?;
    Ok(())
}

pub(crate) fn pending(connection: &Connection) -> Result<usize> {
    Ok(connection.query_row("SELECT count(*) FROM events", [], |row| row.get(0))?)
}

fn purge(transaction: &Transaction, created_before: i64) -> Result<()> {
    let purged =
        transaction.execute("DELETE FROM events WHERE created_at < ?1", [created_before])?;
    if purged > 0 {
        log::warn!("ClickMan deleted {purged} events that waited past max_age unsent");
    }
    Ok(())
}

fn is_due(connection: &Connection, config: &Config, now: i64, urgency: Urgency) -> Result<bool> {
    let (waiting, oldest): (usize, Option<i64>) =
        connection.query_row("SELECT count(*), min(created_at) FROM events", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;
    Ok(match (oldest, urgency) {
        (None, _) => false,
        (Some(_), Urgency::Forced) => true,
        (Some(oldest), Urgency::Due) => {
            waiting >= config.flush_at
                || now.saturating_sub(oldest) >= millis(config.flush_interval)
        }
    })
}

fn oldest(connection: &Connection, max_events: usize) -> Result<Vec<(i64, String)>> {
    let mut statement = connection.prepare("SELECT seq, body FROM events ORDER BY seq LIMIT ?1")?;
    let rows = statement.query_map([sql_count(max_events)], |row| {
        Ok((row.get(0)?, row.get(1)?))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
