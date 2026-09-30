use std::str::FromStr;
use std::time::Duration;

use anyhow::Context;
use clickman_protocol::Event;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::types::Json;
use sqlx::{PgPool, SqlitePool};
use time::{OffsetDateTime, UtcOffset};
use uuid::Uuid;

const SQLITE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const SETTINGS: &str = "SELECT value FROM clickman_settings WHERE key = 'ingest'";

/// ClickMan's database: PostgreSQL, or SQLite for an app that runs on one
/// server. `sqlite:` URLs open SQLite; anything else is PostgreSQL.
#[derive(Clone)]
pub enum Database {
    Postgres(PgPool),
    Sqlite(SqlitePool),
}

impl Database {
    pub async fn connect(url: &str, pool_size: u32) -> anyhow::Result<Self> {
        if url.starts_with("sqlite:") {
            let options = SqliteConnectOptions::from_str(url)
                .context("read the SQLite database URL")?
                .journal_mode(SqliteJournalMode::Wal)
                .busy_timeout(SQLITE_BUSY_TIMEOUT);
            let pool = SqlitePoolOptions::new()
                .max_connections(pool_size)
                .connect_with(options)
                .await
                .context("open the SQLite database")?;
            return Ok(Self::Sqlite(pool));
        }

        let pool = PgPoolOptions::new()
            .max_connections(pool_size)
            .after_connect(|connection, _metadata| {
                Box::pin(async move {
                    sqlx::query("SET TIME ZONE 'UTC'")
                        .execute(connection)
                        .await?;
                    Ok(())
                })
            })
            .connect(url)
            .await
            .context("connect to PostgreSQL")?;
        Ok(Self::Postgres(pool))
    }

    /// Writes accepted events to `clickman_events` in one statement and returns
    /// how many were new; the rest were duplicates of stored message ids.
    pub async fn insert(&self, events: &[Event], received_at: OffsetDateTime) -> sqlx::Result<u64> {
        if events.is_empty() {
            return Ok(0);
        }

        match self {
            Self::Postgres(pool) => insert_postgres(pool, events, received_at).await,
            Self::Sqlite(pool) => insert_sqlite(pool, events, received_at).await,
        }
    }

    /// The published ingest settings, if the engine has published any.
    pub async fn settings(&self) -> sqlx::Result<Option<Value>> {
        match self {
            Self::Postgres(pool) => sqlx::query_scalar(SETTINGS).fetch_optional(pool).await,
            Self::Sqlite(pool) => {
                let value: Option<Json<Value>> =
                    sqlx::query_scalar(SETTINGS).fetch_optional(pool).await?;
                Ok(value.map(|Json(value)| value))
            }
        }
    }

    pub async fn missing_tables(&self, tables: &[&str]) -> sqlx::Result<Vec<String>> {
        match self {
            Self::Postgres(pool) => {
                sqlx::query_scalar(
                    "SELECT name FROM unnest($1::text[]) AS name WHERE to_regclass(name) IS NULL",
                )
                .bind(tables)
                .fetch_all(pool)
                .await
            }
            Self::Sqlite(pool) => {
                let present: Vec<String> =
                    sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table'")
                        .fetch_all(pool)
                        .await?;
                Ok(tables
                    .iter()
                    .filter(|table| !present.iter().any(|name| name == *table))
                    .map(|table| (*table).to_owned())
                    .collect())
            }
        }
    }

    pub async fn close(&self) {
        match self {
            Self::Postgres(pool) => pool.close().await,
            Self::Sqlite(pool) => pool.close().await,
        }
    }
}

async fn insert_postgres(
    pool: &PgPool,
    events: &[Event],
    received_at: OffsetDateTime,
) -> sqlx::Result<u64> {
    let message_ids: Vec<Uuid> = events.iter().map(|event| event.message_id).collect();
    let occurred_at: Vec<OffsetDateTime> = events.iter().map(|event| event.occurred_at).collect();
    let external_ids: Vec<&str> = events
        .iter()
        .map(|event| event.external_id.as_str())
        .collect();
    let names: Vec<&str> = events.iter().map(|event| event.event.as_str()).collect();
    let properties: Vec<Json<Value>> = events
        .iter()
        .map(|event| Json(Value::Object(event.properties.clone())))
        .collect();
    let contexts: Vec<Json<Value>> = events
        .iter()
        .map(|event| Json(Value::Object(event.context.clone())))
        .collect();

    let result = sqlx::query(
        "INSERT INTO clickman_events
           (message_id, occurred_at, received_at, external_id, event, properties, context)
         SELECT message_id, occurred_at, $3, external_id, event, properties, context
         FROM UNNEST($1::uuid[], $2::timestamptz[], $4::text[], $5::text[], $6::jsonb[], $7::jsonb[])
           AS batch (message_id, occurred_at, external_id, event, properties, context)
         ON CONFLICT (message_id) DO NOTHING",
    )
    .bind(message_ids)
    .bind(occurred_at)
    .bind(received_at)
    .bind(external_ids)
    .bind(names)
    .bind(properties)
    .bind(contexts)
    .execute(pool)
    .await?;

    Ok(result.rows_affected())
}

async fn insert_sqlite(
    pool: &SqlitePool,
    events: &[Event],
    received_at: OffsetDateTime,
) -> sqlx::Result<u64> {
    let rows = vec!["(?, ?, ?, ?, ?, ?, ?)"; events.len()].join(", ");
    let sql = format!(
        "INSERT INTO clickman_events
           (message_id, occurred_at, received_at, external_id, event, properties, context)
         VALUES {rows}
         ON CONFLICT (message_id) DO NOTHING"
    );
    let received_at = active_record_time(received_at);

    let mut query = sqlx::query(sqlx::AssertSqlSafe(sql));
    for event in events {
        query = query
            .bind(event.message_id.hyphenated().to_string())
            .bind(active_record_time(event.occurred_at))
            .bind(received_at.clone())
            .bind(event.external_id.as_str())
            .bind(event.event.as_str())
            .bind(Json(&event.properties))
            .bind(Json(&event.context));
    }

    Ok(query.execute(pool).await?.rows_affected())
}

/// Times as Rails writes them to SQLite, so both sides compare them as text:
/// `2026-09-23 12:00:00`, with `.ffffff` only when there are microseconds.
fn active_record_time(time: OffsetDateTime) -> String {
    let time = time.to_offset(UtcOffset::UTC);
    let seconds = format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        time.year(),
        u8::from(time.month()),
        time.day(),
        time.hour(),
        time.minute(),
        time.second()
    );

    match time.microsecond() {
        0 => seconds,
        micros => format!("{seconds}.{micros:06}"),
    }
}

#[cfg(test)]
mod tests {
    use time::macros::datetime;

    use super::active_record_time;

    #[test]
    fn times_are_written_the_way_rails_writes_them_to_sqlite() {
        assert_eq!(
            active_record_time(datetime!(2026-09-23 12:00:00 UTC)),
            "2026-09-23 12:00:00"
        );
        assert_eq!(
            active_record_time(datetime!(2026-09-23 15:00:00.25 +03:00)),
            "2026-09-23 12:00:00.250000"
        );
    }
}
