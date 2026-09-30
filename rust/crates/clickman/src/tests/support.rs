use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use flate2::read::GzDecoder;
use parking_lot::Mutex;
use serde_json::Value;
use tempfile::TempDir;
use time::OffsetDateTime;
use time::macros::datetime;

use crate::clock::{Clock, millis, unix_millis};
use crate::transport::{BoxFuture, HttpClient, HttpResponse};
use crate::{ClickMan, Config};

/// Where every fake clock starts.
pub(crate) const START: OffsetDateTime = datetime!(2026-09-30 12:00:00.123 UTC);

/// A clock that moves only when the test moves it.
#[derive(Clone)]
pub(crate) struct FakeClock(Arc<AtomicI64>);

impl FakeClock {
    pub(crate) fn new() -> Self {
        Self(Arc::new(AtomicI64::new(unix_millis(START))))
    }

    pub(crate) fn advance(&self, by: Duration) {
        self.0.fetch_add(millis(by), Ordering::SeqCst);
    }

    pub(crate) fn clock(&self) -> Clock {
        let now = self.0.clone();
        Arc::new(move || {
            OffsetDateTime::from_unix_timestamp_nanos(
                i128::from(now.load(Ordering::SeqCst)) * 1_000_000,
            )
            .unwrap()
        })
    }
}

/// A request an HTTP stub received.
#[derive(Clone, Debug)]
pub(crate) struct Posted {
    pub(crate) url: String,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: Vec<u8>,
}

impl Posted {
    /// The body, inflated.
    pub(crate) fn payload(&self) -> String {
        let mut payload = String::new();
        GzDecoder::new(self.body.as_slice())
            .read_to_string(&mut payload)
            .unwrap();
        payload
    }

    pub(crate) fn events(&self) -> Vec<Value> {
        let payload: Value = serde_json::from_str(&self.payload()).unwrap();
        payload["batch"].as_array().unwrap().clone()
    }

    pub(crate) fn event_names(&self) -> Vec<String> {
        self.events()
            .iter()
            .map(|event| event["event"].as_str().unwrap().to_owned())
            .collect()
    }
}

/// An HTTP stack answering from a script, then 202 once it runs out.
#[derive(Clone, Default)]
pub(crate) struct StubHttp(Arc<StubScript>);

#[derive(Default)]
struct StubScript {
    answers: Mutex<VecDeque<Result<HttpResponse, String>>>,
    posted: Mutex<Vec<Posted>>,
}

impl StubHttp {
    pub(crate) fn answering(
        answers: impl IntoIterator<Item = Result<HttpResponse, String>>,
    ) -> Self {
        let stub = Self::default();
        stub.0.answers.lock().extend(answers);
        stub
    }

    pub(crate) fn posted(&self) -> Vec<Posted> {
        self.0.posted.lock().clone()
    }
}

impl HttpClient for StubHttp {
    fn post<'a>(
        &'a self,
        url: &'a str,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> BoxFuture<'a, Result<HttpResponse, String>> {
        self.0.posted.lock().push(Posted {
            url: url.to_owned(),
            headers,
            body,
        });
        let answer = self
            .0
            .answers
            .lock()
            .pop_front()
            .unwrap_or_else(|| Ok(status(202)));
        Box::pin(async move { answer })
    }
}

pub(crate) fn status(status: u16) -> HttpResponse {
    HttpResponse {
        status,
        retry_after: None,
    }
}

pub(crate) fn retry_after(status: u16, seconds: &str) -> HttpResponse {
    HttpResponse {
        status,
        retry_after: Some(seconds.to_owned()),
    }
}

/// A client on a scratch store, the fake clock and the stub; the jitter factor is fixed at 1.
pub(crate) struct Harness {
    pub(crate) clickman: ClickMan,
    pub(crate) http: StubHttp,
    pub(crate) clock: FakeClock,
    pub(crate) config: Config,
    pub(crate) dir: TempDir,
}

impl Harness {
    pub(crate) fn new() -> Self {
        Self::with(|_| {}, [])
    }

    pub(crate) fn with(
        configure: impl FnOnce(&mut Config),
        answers: impl IntoIterator<Item = Result<HttpResponse, String>>,
    ) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let mut config = scratch_config(&dir);
        configure(&mut config);
        Self::open(dir, config, FakeClock::new(), StubHttp::answering(answers))
    }

    /// Closes the client and opens a new one on the same store and clock.
    pub(crate) fn reopen(
        self,
        answers: impl IntoIterator<Item = Result<HttpResponse, String>>,
    ) -> Self {
        let Self {
            clickman,
            clock,
            config,
            dir,
            ..
        } = self;
        drop(clickman);
        Self::open(dir, config, clock, StubHttp::answering(answers))
    }

    fn open(dir: TempDir, config: Config, clock: FakeClock, http: StubHttp) -> Self {
        let clickman = open_client(config.clone(), http.clone(), &clock);
        Self {
            clickman,
            http,
            clock,
            config,
            dir,
        }
    }

    pub(crate) fn stored(&self) -> Vec<Value> {
        stored(&self.config.path)
    }

    pub(crate) fn stored_names(&self) -> Vec<String> {
        self.stored()
            .iter()
            .map(|body| body["event"].as_str().unwrap().to_owned())
            .collect()
    }

    pub(crate) fn raw(&self) -> rusqlite::Connection {
        rusqlite::Connection::open(&self.config.path).unwrap()
    }
}

pub(crate) fn scratch_config(dir: &TempDir) -> Config {
    Config::new(
        "https://ingest.test",
        "wk_test",
        dir.path().join("queue.sqlite"),
    )
}

pub(crate) fn open_client(
    config: Config,
    http: impl HttpClient + 'static,
    clock: &FakeClock,
) -> ClickMan {
    ClickMan::open_with(config, Box::new(http), clock.clock(), Arc::new(|| 0.5)).unwrap()
}

/// The stored bodies as text, oldest first, read through a connection of their own.
pub(crate) fn stored_texts(path: &Path) -> Vec<String> {
    let connection = rusqlite::Connection::open(path).unwrap();
    let mut statement = connection
        .prepare("SELECT body FROM events ORDER BY seq")
        .unwrap();
    let bodies = statement.query_map([], |row| row.get(0)).unwrap();
    bodies.collect::<rusqlite::Result<_>>().unwrap()
}

pub(crate) fn stored(path: &Path) -> Vec<Value> {
    stored_texts(path)
        .iter()
        .map(|text| serde_json::from_str(text).unwrap())
        .collect()
}

pub(crate) fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../protocol/fixtures")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).unwrap()
}
