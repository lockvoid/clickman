mod support;

use std::path::Path;
use std::time::SystemTime;

use clickman::Error;
use rusqlite::{Connection, params};
use serde_json::json;

use support::{StubServer, config, open, scratch, store_path, try_open};

const OLD_CORE_SCHEMA: &str = "
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL, body TEXT NOT NULL, batch_id INTEGER);
    CREATE INDEX events_batch ON events (batch_id);
    CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
";

#[tokio::test]
async fn reopening_keeps_the_events_and_the_identity() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    let clickman = open(config(&server.endpoint, &dir));
    clickman.identify("user_7").unwrap();
    clickman.set_traits(json!({"plan": "pro"})).unwrap();
    clickman.track("before", json!({})).unwrap();
    drop(clickman);
    let clickman = open(config(&server.endpoint, &dir));
    assert_eq!(clickman.pending().unwrap(), 1);
    clickman.track("after", json!({})).unwrap();
    clickman.flush().await.unwrap();
    assert_eq!(server.event_names(), ["before", "after"]);
    for event in server.received()[0].events() {
        assert_eq!(
            (&event["externalId"], &event["context"]["traits"]),
            (&json!("user_7"), &json!({"plan": "pro"}))
        );
    }
}

#[tokio::test]
async fn a_launch_after_reopening_compares_with_the_last_launch() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    for (version, build) in [("1.0", "10"), ("1.0", "10"), ("1.1", "11")] {
        open(config(&server.endpoint, &dir))
            .app_launched(version, build)
            .unwrap();
    }
    open(config(&server.endpoint, &dir)).flush().await.unwrap();
    let names = [
        "app_installed",
        "app_opened",
        "app_opened",
        "app_updated",
        "app_opened",
    ];
    assert_eq!(server.event_names(), names);
    let updated = &server.received()[0].events()[3]["properties"];
    let expected =
        json!({"version": "1.1", "build": "11", "previous_version": "1.0", "previous_build": "10"});
    assert_eq!(updated, &expected);
}

fn write_old_core_store(path: &Path, event: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let connection = Connection::open(path).unwrap();
    connection.execute_batch(OLD_CORE_SCHEMA).unwrap();
    let state = [
        ("external_id", "user_9"),
        ("traits", r#"{"plan":"pro"}"#),
        ("app_version", "1.0"),
        ("app_build", "10"),
    ];
    for (key, value) in state {
        connection
            .execute(
                "INSERT INTO state (key, value) VALUES (?1, ?2)",
                [key, value],
            )
            .unwrap();
    }
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let sql = "INSERT INTO events (created_at, body, batch_id) VALUES (?1, ?2, 3)";
    connection.execute(sql, params![now, event]).unwrap();
}

fn old_core_event() -> String {
    let event = json!({
        "type": "track",
        "messageId": "0192f5c4-6b3a-7c3d-9f2e-5b1a2c3d4e5f",
        "event": "old_core_event",
        "externalId": "user_9",
        "timestamp": "2026-09-30T11:59:00.000Z",
        "properties": {},
        "context": {"os": {"name": "iOS"}},
    });
    event.to_string()
}

#[tokio::test]
async fn a_format_0_store_of_the_old_core_is_adopted() {
    let server = StubServer::start([]).await;
    let dir = scratch();
    write_old_core_store(&store_path(&dir), &old_core_event());
    let clickman = open(config(&server.endpoint, &dir));
    clickman.app_launched("1.0", "10").unwrap();
    clickman.track("after", json!({})).unwrap();
    clickman.flush().await.unwrap();
    let received = &server.received()[0];
    assert!(received.payload.contains(&old_core_event()));
    assert_eq!(
        server.event_names(),
        ["old_core_event", "app_opened", "after"]
    );
    let after = &received.events()[2];
    assert_eq!(
        (&after["externalId"], &after["context"]["traits"]),
        (&json!("user_9"), &json!({"plan": "pro"}))
    );
    assert_eq!(
        tables_and_format(&store_path(&dir)),
        (vec!["events".to_owned(), "identity".to_owned()], 1)
    );
}

fn tables_and_format(path: &Path) -> (Vec<String>, i64) {
    let connection = Connection::open(path).unwrap();
    let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name";
    let mut statement = connection.prepare(sql).unwrap();
    let tables = statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let format = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    (tables, format)
}

#[test]
fn a_store_of_a_later_format_is_refused() {
    let dir = scratch();
    let path = store_path(&dir);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    Connection::open(&path)
        .unwrap()
        .pragma_update(None, "user_version", 2)
        .unwrap();
    match try_open(config("http://127.0.0.1:9", &dir)) {
        Err(Error::NewerStore { format }) => assert_eq!(format, 2),
        Err(other) => panic!("refused for the wrong reason: {other}"),
        Ok(_) => panic!("a store of format 2 opened"),
    }
    assert_eq!(tables_and_format(&path), (Vec::<String>::new(), 2));
}
