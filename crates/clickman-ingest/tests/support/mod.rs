use std::io::Write;
use std::path::PathBuf;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use clickman_ingest::Database;
use flate2::Compression;
use flate2::write::GzEncoder;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::types::Json;
use sqlx::{ConnectOptions, Connection, PgConnection, Row};
use std::str::FromStr;
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, PrimitiveDateTime};
use tower::ServiceExt;
use uuid::Uuid;

pub const WRITE_KEY: &str = "test-write-key";

/// A throwaway database carrying the v1 schema, dropped when the test ends.
pub struct TestDatabase {
    pub database: Database,
    cleanup: Cleanup,
}

enum Cleanup {
    Postgres { name: String, admin_url: String },
    Sqlite { path: PathBuf },
}

/// A stored raw event, read the same way from either database.
pub struct Stored {
    pub message_id: Uuid,
    pub event: String,
    pub external_id: String,
    pub properties: Value,
    pub context: Value,
    pub occurred_at: OffsetDateTime,
}

impl TestDatabase {
    pub async fn postgres() -> Self {
        let admin_url = std::env::var("CLICKMAN_TEST_DATABASE_URL").unwrap_or_else(|_| {
            let user = std::env::var("USER").unwrap_or_else(|_| "postgres".to_owned());
            format!("postgres://{user}@localhost/postgres")
        });
        let name = format!("clickman_ingest_test_{}", Uuid::now_v7().simple());

        let mut admin = PgConnection::connect(&admin_url)
            .await
            .expect("connect to the admin database; set CLICKMAN_TEST_DATABASE_URL");
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE DATABASE {name}")))
            .execute(&mut admin)
            .await
            .unwrap();
        admin.close().await.unwrap();

        let options = PgConnectOptions::from_str(&admin_url)
            .unwrap()
            .database(&name)
            .disable_statement_logging();
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .connect_with(options)
            .await
            .unwrap();
        sqlx::raw_sql(sqlx::AssertSqlSafe(schema("postgres")))
            .execute(&pool)
            .await
            .unwrap();

        Self {
            database: Database::Postgres(pool),
            cleanup: Cleanup::Postgres { name, admin_url },
        }
    }

    pub async fn sqlite() -> Self {
        let path = std::env::temp_dir().join(format!(
            "clickman-ingest-{}.sqlite3",
            Uuid::now_v7().simple()
        ));
        let database = Database::connect(&format!("sqlite://{}?mode=rwc", path.display()), 4)
            .await
            .unwrap();
        let Database::Sqlite(pool) = &database else {
            unreachable!("a sqlite URL opens SQLite")
        };
        sqlx::raw_sql(sqlx::AssertSqlSafe(schema("sqlite")))
            .execute(pool)
            .await
            .unwrap();

        Self {
            database,
            cleanup: Cleanup::Sqlite { path },
        }
    }

    pub async fn publish_settings(&self, settings: Value) {
        match &self.database {
            Database::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO clickman_settings (key, value) VALUES ('ingest', $1)
                     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
                )
                .bind(settings)
                .execute(pool)
                .await
                .unwrap();
            }
            Database::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO clickman_settings (key, value) VALUES ('ingest', ?)
                     ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP",
                )
                .bind(Json(settings))
                .execute(pool)
                .await
                .unwrap();
            }
        }
    }

    pub async fn stored(&self) -> Vec<Stored> {
        match &self.database {
            Database::Postgres(pool) => sqlx::query(
                "SELECT message_id, occurred_at, external_id, event, properties, context
                 FROM clickman_events ORDER BY occurred_at",
            )
            .fetch_all(pool)
            .await
            .unwrap()
            .into_iter()
            .map(|row| Stored {
                message_id: row.get("message_id"),
                event: row.get("event"),
                external_id: row.get("external_id"),
                properties: row.get("properties"),
                context: row.get("context"),
                occurred_at: row.get("occurred_at"),
            })
            .collect(),
            Database::Sqlite(pool) => sqlx::query(
                "SELECT message_id, occurred_at, external_id, event, properties, context
                 FROM clickman_events ORDER BY occurred_at",
            )
            .fetch_all(pool)
            .await
            .unwrap()
            .into_iter()
            .map(|row| Stored {
                message_id: row.get::<String, _>("message_id").parse().unwrap(),
                event: row.get("event"),
                external_id: row.get("external_id"),
                properties: serde_json::from_str(&row.get::<String, _>("properties")).unwrap(),
                context: serde_json::from_str(&row.get::<String, _>("context")).unwrap(),
                occurred_at: active_record_time(&row.get::<String, _>("occurred_at")),
            })
            .collect(),
        }
    }

    pub async fn drop_table(&self, table: &str) {
        let sql = sqlx::AssertSqlSafe(format!("DROP TABLE {table}"));
        match &self.database {
            Database::Postgres(pool) => sqlx::query(sql).execute(pool).await.map(drop),
            Database::Sqlite(pool) => sqlx::query(sql).execute(pool).await.map(drop),
        }
        .unwrap();
    }
}

fn schema(adapter: &str) -> String {
    std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!("../../sql/{adapter}/v1.sql")),
    )
    .unwrap()
}

fn active_record_time(text: &str) -> OffsetDateTime {
    let format = if text.contains('.') {
        format_description!("[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:6]")
    } else {
        format_description!("[year]-[month]-[day] [hour]:[minute]:[second]")
    };
    PrimitiveDateTime::parse(text, format).unwrap().assume_utc()
}

// The pool belongs to the test's runtime, which this thread blocks while it
// waits; touching the pool here would deadlock. FORCE ends its connections.
impl Drop for TestDatabase {
    fn drop(&mut self) {
        let (name, admin_url) = match &self.cleanup {
            Cleanup::Sqlite { path } => {
                for suffix in ["", "-wal", "-shm"] {
                    let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
                }
                return;
            }
            Cleanup::Postgres { name, admin_url } => (name.clone(), admin_url.clone()),
        };

        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                if let Ok(mut admin) = PgConnection::connect(&admin_url).await {
                    let _ = sqlx::query(sqlx::AssertSqlSafe(format!(
                        "DROP DATABASE IF EXISTS {name} WITH (FORCE)"
                    )))
                    .execute(&mut admin)
                    .await;
                }
            });
        })
        .join()
        .unwrap();
    }
}

pub fn default_settings() -> Value {
    json!({
        "writeKeys": [{ "name": "test", "digest": clickman_ingest::digest(WRITE_KEY) }],
        "fragments": clickman_protocol::DEFAULT_FRAGMENTS,
        "maxEventAgeDays": 90,
        "rateLimit": { "perSecond": 1000, "burst": 1000 },
    })
}

pub fn now() -> OffsetDateTime {
    OffsetDateTime::now_utc()
}

pub fn rfc3339(time: OffsetDateTime) -> String {
    time.format(&Rfc3339).unwrap()
}

pub fn event(message_id: Uuid, overrides: Value) -> Value {
    let mut event = json!({
        "type": "track",
        "messageId": message_id.to_string(),
        "event": "export_completed",
        "externalId": "user_42",
        "timestamp": rfc3339(now()),
        "properties": { "format": "mp4" },
    });
    for (key, value) in overrides.as_object().unwrap() {
        event[key] = value.clone();
    }
    event
}

pub fn batch(events: Vec<Value>) -> Value {
    json!({ "sentAt": rfc3339(now()), "batch": events })
}

pub fn gzip(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(bytes).unwrap();
    encoder.finish().unwrap()
}

pub struct Response {
    pub status: StatusCode,
    pub headers: axum::http::HeaderMap,
    pub json: Value,
}

pub async fn post(router: &Router, body: Vec<u8>, headers: &[(&str, &str)]) -> Response {
    let mut request = Request::post("/v1/batch").header("content-type", "application/json");
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = router
        .clone()
        .oneshot(request.body(Body::from(body)).unwrap())
        .await
        .unwrap();

    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let json = serde_json::from_slice(&bytes).unwrap_or(Value::Null);

    Response {
        status,
        headers,
        json,
    }
}

pub const AUTHORIZATION: (&str, &str) = ("authorization", "Bearer test-write-key");
pub const GZIP: (&str, &str) = ("content-encoding", "gzip");
