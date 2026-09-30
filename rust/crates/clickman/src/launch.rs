use rusqlite::{Connection, params};
use serde_json::{Map, Value};

use crate::error::Result;
use crate::event::Recorder;

/// An app's version and build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Release {
    pub(crate) version: String,
    pub(crate) build: String,
}

/// Records the launch of `release` and remembers it as the last launch.
pub(crate) fn record(recorder: &Recorder, release: &Release) -> Result<()> {
    for (event, properties) in events(last_launch(recorder.transaction)?.as_ref(), release) {
        recorder.record(event, properties)?;
    }
    recorder.transaction.execute(
        "UPDATE identity SET app_version = ?1, app_build = ?2 WHERE id = 1",
        params![release.version, release.build],
    )?;
    Ok(())
}

/// The events a launch of `release` records after `last`, the launch the store remembers (lifecycle.json).
pub(crate) fn events(
    last: Option<&Release>,
    release: &Release,
) -> Vec<(&'static str, Map<String, Value>)> {
    let opened = (
        "app_opened",
        properties([("from_background", false.into())]),
    );
    match last {
        None => vec![("app_installed", installed(release)), opened],
        Some(last) if last != release => vec![("app_updated", updated(last, release)), opened],
        Some(_) => vec![opened],
    }
}

fn installed(release: &Release) -> Map<String, Value> {
    properties([
        ("version", release.version.as_str().into()),
        ("build", release.build.as_str().into()),
    ])
}

fn updated(last: &Release, release: &Release) -> Map<String, Value> {
    let mut properties = installed(release);
    properties.insert("previous_version".to_owned(), last.version.as_str().into());
    properties.insert("previous_build".to_owned(), last.build.as_str().into());
    properties
}

fn properties<const N: usize>(pairs: [(&str, Value); N]) -> Map<String, Value> {
    pairs
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect()
}

fn last_launch(connection: &Connection) -> Result<Option<Release>> {
    let (version, build): (Option<String>, Option<String>) = connection.query_row(
        "SELECT app_version, app_build FROM identity WHERE id = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok(version
        .zip(build)
        .map(|(version, build)| Release { version, build }))
}
