use std::io::Write;

use clickman::{BoxFuture, ClickMan, Config, HttpClient, HttpResponse};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};

type Failure = Box<dyn std::error::Error + Send + Sync>;

struct Network(reqwest::Client);

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
        let retry_after = retry_after(&response);
        Ok(HttpResponse {
            status,
            retry_after,
        })
    }
}

fn retry_after(response: &reqwest::Response) -> Option<String> {
    let value = response.headers().get(reqwest::header::RETRY_AFTER)?;
    Some(String::from_utf8_lossy(value.as_bytes()).into_owned())
}

/// Logs to stderr: stdout carries only protocol lines.
struct StderrLog;

impl log::Log for StderrLog {
    fn enabled(&self, _: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        eprintln!("{} {}", record.level(), record.args());
    }

    fn flush(&self) {}
}

static LOG: StderrLog = StderrLog;

#[tokio::main]
async fn main() -> Result<(), Failure> {
    log::set_logger(&LOG)?;
    log::set_max_level(log::LevelFilter::Info);
    let clickman = start(std::env::args().skip(1).collect())?;
    emit(&json!({"ready": true, "language": "rust"}))?;
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        emit(&answer(&clickman, &line).await)?;
    }
    Ok(())
}

fn start(arguments: Vec<String>) -> Result<ClickMan, Failure> {
    let [endpoint, write_key, store] = <[String; 3]>::try_from(arguments).map_err(usage)?;
    let config = Config::new(endpoint, write_key, store);
    let clickman = ClickMan::open(config, Network(reqwest::Client::new()))?;
    clickman.set_context(context())?;
    clickman.app_launched("e2e", "1")?;
    Ok(clickman)
}

fn usage(arguments: Vec<String>) -> String {
    let count = arguments.len();
    format!("usage: clickman-e2e-worker <endpoint> <write-key> <store-path>, got {count} arguments")
}

fn context() -> Value {
    json!({
        "app": {"name": "clickman-e2e-worker"},
        "os": {"name": std::env::consts::OS},
    })
}

async fn answer(clickman: &ClickMan, line: &str) -> Value {
    match execute(clickman, line).await {
        Ok(fields) => {
            let mut answer = fields_of([("ok", Value::Bool(true))]);
            answer.extend(fields);
            Value::Object(answer)
        }
        Err(error) => json!({"ok": false, "error": error.to_string()}),
    }
}

async fn execute(clickman: &ClickMan, line: &str) -> Result<Map<String, Value>, Failure> {
    let request: Value = serde_json::from_str(line)?;
    match text(&request, "command")? {
        "identify" => clickman.identify(text(&request, "externalId")?)?,
        "traits" => clickman.set_traits(field(&request, "traits")?.clone())?,
        "track" => return track(clickman, &request),
        "reset" => clickman.reset()?,
        "flush" => return flush(clickman).await,
        "pending" => return pending(clickman),
        unknown => return Err(format!("unknown command {unknown}").into()),
    }
    Ok(Map::new())
}

async fn flush(clickman: &ClickMan) -> Result<Map<String, Value>, Failure> {
    clickman.flush().await?;
    pending(clickman)
}

fn track(clickman: &ClickMan, request: &Value) -> Result<Map<String, Value>, Failure> {
    let message_id = clickman.track(text(request, "event")?, request["properties"].clone())?;
    Ok(fields_of([("messageId", message_id.to_string().into())]))
}

fn pending(clickman: &ClickMan) -> Result<Map<String, Value>, Failure> {
    Ok(fields_of([("pending", clickman.pending()?.into())]))
}

fn field<'a>(request: &'a Value, name: &str) -> Result<&'a Value, Failure> {
    request
        .get(name)
        .ok_or_else(|| format!("the command has no {name}").into())
}

fn text<'a>(request: &'a Value, name: &str) -> Result<&'a str, Failure> {
    field(request, name)?
        .as_str()
        .ok_or_else(|| format!("{name} is not a string").into())
}

fn fields_of<const N: usize>(pairs: [(&str, Value); N]) -> Map<String, Value> {
    pairs
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect()
}

fn emit(line: &Value) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}")?;
    stdout.flush()
}
