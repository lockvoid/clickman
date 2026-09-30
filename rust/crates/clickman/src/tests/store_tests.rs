use std::path::PathBuf;

use rusqlite::Connection;
use tempfile::TempDir;

use crate::error::{Error, Result};
use crate::store::Store;

const OLD_CORE_SCHEMA: &str = "
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL, body TEXT NOT NULL, batch_id INTEGER);
    CREATE INDEX events_batch ON events (batch_id);
    CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
";

type IdentityRow = (String, String, Option<String>, Option<String>);

fn identity(connection: &Connection) -> IdentityRow {
    let sql = "SELECT external_id, traits, app_version, app_build FROM identity";
    connection
        .query_row(sql, [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .unwrap()
}

fn user_version(connection: &Connection) -> i64 {
    connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap()
}

fn names(connection: &Connection, kind: &str) -> Vec<String> {
    let mut statement = connection
        .prepare("SELECT name FROM sqlite_master WHERE type = ?1 ORDER BY name")
        .unwrap();
    let names = statement.query_map([kind], |row| row.get(0)).unwrap();
    names.collect::<rusqlite::Result<_>>().unwrap()
}

fn events(connection: &Connection) -> i64 {
    connection
        .query_row("SELECT count(*) FROM events", [], |row| row.get(0))
        .unwrap()
}

fn old_core_store(dir: &TempDir, state: &[(&str, &str)]) -> PathBuf {
    let path = dir.path().join("queue.sqlite");
    let connection = Connection::open(&path).unwrap();
    connection.execute_batch(OLD_CORE_SCHEMA).unwrap();
    for (key, value) in state {
        connection
            .execute(
                "INSERT INTO state (key, value) VALUES (?1, ?2)",
                [key, value],
            )
            .unwrap();
    }
    let sql = r#"INSERT INTO events (created_at, body, batch_id) VALUES (1, '{"event":"old"}', 7)"#;
    connection.execute(sql, []).unwrap();
    path
}

#[test]
fn a_new_store_is_format_1_in_wal_mode_under_new_directories_with_an_anonymous_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a").join("b").join("queue.sqlite");
    let _store = Store::open(&path).unwrap();
    let raw = Connection::open(&path).unwrap();
    assert_eq!(user_version(&raw), 1);
    let journal_mode: String = raw
        .pragma_query_value(None, "journal_mode", |row| row.get(0))
        .unwrap();
    assert_eq!(journal_mode, "wal");
    assert_eq!(
        identity(&raw),
        ("*".to_owned(), "{}".to_owned(), None, None)
    );
    assert_eq!(events(&raw), 0);
}

#[test]
fn reopening_a_current_store_keeps_its_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite");
    let store = Store::open(&path).unwrap();
    let sql = "INSERT INTO events (created_at, body) VALUES (1, '{}'); UPDATE identity SET external_id = 'user_1';";
    store
        .write(|transaction| Ok(transaction.execute_batch(sql)?))
        .unwrap();
    drop(store);
    let _store = Store::open(&path).unwrap();
    let raw = Connection::open(&path).unwrap();
    assert_eq!((user_version(&raw), events(&raw)), (1, 1));
    assert_eq!(identity(&raw).0, "user_1");
}

#[test]
fn a_format_0_store_of_the_old_core_is_adopted() {
    let dir = tempfile::tempdir().unwrap();
    let state = [
        ("external_id", "user_9"),
        ("traits", r#"{"plan":"pro"}"#),
        ("app_version", "1.0"),
        ("app_build", "10"),
        ("context", r#"{"os":{"name":"iOS"}}"#),
    ];
    let path = old_core_store(&dir, &state);
    let _store = Store::open(&path).unwrap();
    let raw = Connection::open(&path).unwrap();
    assert_eq!(user_version(&raw), 1);
    let adopted = (
        "user_9".to_owned(),
        r#"{"plan":"pro"}"#.to_owned(),
        Some("1.0".to_owned()),
        Some("10".to_owned()),
    );
    assert_eq!(identity(&raw), adopted);
    assert!(!names(&raw, "table").contains(&"state".to_owned()));
    assert!(!names(&raw, "index").contains(&"events_batch".to_owned()));
    let body: String = raw
        .query_row("SELECT body FROM events", [], |row| row.get(0))
        .unwrap();
    assert_eq!(body, r#"{"event":"old"}"#);
}

#[test]
fn an_old_store_that_never_identified_or_launched_keeps_the_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let path = old_core_store(&dir, &[]);
    let _store = Store::open(&path).unwrap();
    let raw = Connection::open(&path).unwrap();
    assert_eq!(
        identity(&raw),
        ("*".to_owned(), "{}".to_owned(), None, None)
    );
    assert_eq!(events(&raw), 1);
}

#[test]
fn a_store_of_a_later_format_is_refused_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite");
    Connection::open(&path)
        .unwrap()
        .pragma_update(None, "user_version", 2)
        .unwrap();
    assert!(matches!(
        Store::open(&path),
        Err(Error::NewerStore { format: 2 })
    ));
    let raw = Connection::open(&path).unwrap();
    assert_eq!(user_version(&raw), 2);
    assert!(names(&raw, "table").is_empty());
}

#[test]
fn a_store_of_a_negative_format_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite");
    Connection::open(&path)
        .unwrap()
        .pragma_update(None, "user_version", -1)
        .unwrap();
    assert!(matches!(
        Store::open(&path),
        Err(Error::UnknownStore { format: -1 })
    ));
}

#[test]
fn a_failed_write_commits_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("queue.sqlite");
    let store = Store::open(&path).unwrap();
    let written: Result<()> = store.write(|transaction| {
        transaction.execute("INSERT INTO events (created_at, body) VALUES (1, '{}')", [])?;
        Err(Error::InvalidEvent)
    });
    assert!(matches!(written, Err(Error::InvalidEvent)));
    assert_eq!(events(&Connection::open(&path).unwrap()), 0);
}

#[test]
fn a_store_whose_directory_cannot_be_made_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("file");
    std::fs::write(&file, b"").unwrap();
    let opened = Store::open(&file.join("queue.sqlite"));
    assert!(matches!(opened, Err(Error::StoreDirectory { path, .. }) if path == file));
}
