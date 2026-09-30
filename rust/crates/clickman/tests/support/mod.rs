#![allow(dead_code)]

use std::collections::VecDeque;
use std::io::Read;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use clickman::{BoxFuture, ClickMan, Config, HttpClient, HttpResponse};
use flate2::read::GzDecoder;
use serde_json::Value;
use tempfile::TempDir;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

pub const WRITE_KEY: &str = "wk_integration";

/// One batch as the stub server received it.
#[derive(Clone, Debug)]
pub struct Received {
    pub headers: HeaderMap,
    /// The body, inflated.
    pub payload: String,
}

impl Received {
    pub fn header(&self, name: &str) -> &str {
        self.headers[name].to_str().unwrap()
    }

    pub fn json(&self) -> Value {
        serde_json::from_str(&self.payload).unwrap()
    }

    pub fn events(&self) -> Vec<Value> {
        self.json()["batch"].as_array().unwrap().clone()
    }
}

/// A status the stub server answers with, and maybe a `Retry-After`.
#[derive(Clone, Copy, Debug)]
pub struct Answer {
    pub status: u16,
    pub retry_after: Option<&'static str>,
}

pub fn answer(status: u16) -> Answer {
    Answer {
        status,
        retry_after: None,
    }
}

/// A stand-in ingest server on a loopback port: it records every batch and
/// answers from its script, then 202.
pub struct StubServer {
    pub endpoint: String,
    script: Arc<Script>,
}

#[derive(Default)]
struct Script {
    answers: Mutex<VecDeque<Answer>>,
    received: Mutex<Vec<Received>>,
}

impl StubServer {
    pub async fn start(answers: impl IntoIterator<Item = Answer>) -> Self {
        let script = Arc::new(Script::default());
        script.answers.lock().unwrap().extend(answers);
        let router = Router::new()
            .route("/v1/batch", post(receive))
            .with_state(script.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        Self { endpoint, script }
    }

    pub fn received(&self) -> Vec<Received> {
        self.script.received.lock().unwrap().clone()
    }

    pub fn event_names(&self) -> Vec<String> {
        let events: Vec<Value> = self.received().iter().flat_map(Received::events).collect();
        events
            .iter()
            .map(|event| event["event"].as_str().unwrap().to_owned())
            .collect()
    }
}

async fn receive(State(script): State<Arc<Script>>, headers: HeaderMap, body: Bytes) -> Response {
    let mut payload = String::new();
    GzDecoder::new(body.as_ref())
        .read_to_string(&mut payload)
        .unwrap();
    script
        .received
        .lock()
        .unwrap()
        .push(Received { headers, payload });
    let answer = script
        .answers
        .lock()
        .unwrap()
        .pop_front()
        .unwrap_or(answer(202));
    let status = StatusCode::from_u16(answer.status).unwrap();
    match answer.retry_after {
        Some(seconds) => (status, [(header::RETRY_AFTER, seconds)]).into_response(),
        None => status.into_response(),
    }
}

/// The host HTTP stack of these tests, reqwest as in the E2E worker.
pub struct Network(reqwest::Client);

impl HttpClient for Network {
    fn post<'a>(
        &'a self,
        url: &'a str,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> BoxFuture<'a, Result<HttpResponse, String>> {
        Box::pin(self.send(url, headers, body))
    }
}

impl Network {
    async fn send(
        &self,
        url: &str,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> Result<HttpResponse, String> {
        let mut request = self.0.post(url).body(body);
        for (name, value) in headers {
            request = request.header(name, value);
        }
        let response = request.send().await.map_err(|error| error.to_string())?;
        let status = response.status().as_u16();
        let retry_after = response.headers().get(reqwest::header::RETRY_AFTER);
        let retry_after = retry_after.map(|value| value.to_str().unwrap().to_owned());
        Ok(HttpResponse {
            status,
            retry_after,
        })
    }
}

pub fn scratch() -> TempDir {
    tempfile::tempdir().unwrap()
}

/// The store sits in a directory the client has to create.
pub fn store_path(dir: &TempDir) -> PathBuf {
    dir.path().join("nested").join("queue.sqlite")
}

pub fn config(endpoint: &str, dir: &TempDir) -> Config {
    Config::new(endpoint, WRITE_KEY, store_path(dir))
}

pub fn try_open(config: Config) -> clickman::Result<ClickMan> {
    ClickMan::open(config, Network(reqwest::Client::new()))
}

pub fn open(config: Config) -> ClickMan {
    try_open(config).unwrap()
}

pub fn assert_rfc3339_millis(text: &str) {
    assert_eq!(
        (text.len(), &text[19..20], &text[23..]),
        (24, ".", "Z"),
        "{text}"
    );
    OffsetDateTime::parse(text, &Rfc3339).unwrap();
}
