use std::sync::Arc;
use std::time::Duration;

use parking_lot::Mutex;

use crate::backoff;
use crate::batch::{self, Batch, Urgency};
use crate::clock::{Clock, millis, rfc3339_millis, unix_millis};
use crate::config::Config;
use crate::error::{Error, Result};
use crate::gzip;
use crate::outcome::Outcome;
use crate::store::Store;
use crate::transport::{HttpClient, HttpResponse};

/// A number in [0, 1).
pub(crate) type Random = Arc<dyn Fn() -> f64 + Send + Sync>;

/// Sends batches one at a time. Failures are counted in memory only, so a
/// restarted client sends what is waiting at once.
pub(crate) struct Sender {
    http: Box<dyn HttpClient>,
    url: String,
    config: Config,
    clock: Clock,
    random: Random,
    state: Mutex<SenderState>,
}

#[derive(Default)]
struct SenderState {
    flight: Flight,
    backoff: Backoff,
}

#[derive(Clone, Copy, Default)]
enum Flight {
    #[default]
    Idle,
    InFlight,
}

/// The consecutive failures, and the time in milliseconds before which nothing is sent.
#[derive(Clone, Copy, Default)]
enum Backoff {
    #[default]
    Clear,
    Waiting {
        failures: u32,
        until: i64,
    },
}

/// The one flight; dropping it, done or cancelled, lets the next batch go.
struct FlightGuard<'a>(&'a Mutex<SenderState>);

impl Drop for FlightGuard<'_> {
    fn drop(&mut self) {
        self.0.lock().flight = Flight::Idle;
    }
}

/// What came back for a batch.
struct Answer {
    status: u16,
    retry_after: Option<Duration>,
}

impl Answer {
    const NO_RESPONSE: Self = Self {
        status: 0,
        retry_after: None,
    };

    fn of(response: HttpResponse) -> Self {
        let retry_after = backoff::retry_after(response.retry_after.as_deref());
        Self {
            status: response.status,
            retry_after,
        }
    }
}

impl Sender {
    pub(crate) fn new(
        http: Box<dyn HttpClient>,
        config: Config,
        clock: Clock,
        random: Random,
    ) -> Self {
        let url = format!("{}/v1/batch", config.endpoint.trim_end_matches('/'));
        let state = Mutex::default();
        Self {
            http,
            url,
            config,
            clock,
            random,
            state,
        }
    }

    /// Sends batches until nothing is due or a send fails.
    pub(crate) async fn drain(&self, store: &Store, urgency: Urgency) -> Result<()> {
        loop {
            match self.send_next(store, urgency).await? {
                Some(Outcome::Delivered | Outcome::Refused) => {}
                Some(Outcome::Retry) | None => return Ok(()),
            }
        }
    }

    /// Sends the next batch, or nothing while one is in flight, a retry waits or nothing is due.
    async fn send_next(&self, store: &Store, urgency: Urgency) -> Result<Option<Outcome>> {
        let now = (self.clock)();
        let Some(_flight) = self.reserve(unix_millis(now)) else {
            return Ok(None);
        };
        let taken = store.write(|transaction| {
            batch::take(transaction, &self.config, unix_millis(now), urgency)
        })?;
        let Some(batch) = taken else { return Ok(None) };
        let answer = self.post(&batch, &rfc3339_millis(now)).await?;
        self.settle(store, &batch, &answer).map(Some)
    }

    fn reserve(&self, now: i64) -> Option<FlightGuard<'_>> {
        let mut state = self.state.lock();
        match (state.flight, state.backoff) {
            (Flight::InFlight, _) => None,
            (Flight::Idle, Backoff::Waiting { until, .. }) if now < until => None,
            (Flight::Idle, _) => {
                state.flight = Flight::InFlight;
                Some(FlightGuard(&self.state))
            }
        }
    }

    async fn post(&self, batch: &Batch, sent_at: &str) -> Result<Answer> {
        let body = gzip::compress(batch.payload(sent_at).as_bytes()).map_err(Error::Compression)?;
        match self.http.post(&self.url, self.headers(), body).await {
            Ok(response) => Ok(Answer::of(response)),
            Err(message) => {
                log::warn!("ClickMan could not reach {}: {message}", self.url);
                Ok(Answer::NO_RESPONSE)
            }
        }
    }

    fn headers(&self) -> Vec<(String, String)> {
        let authorization = format!("Bearer {}", self.config.write_key);
        vec![
            ("Authorization".to_owned(), authorization),
            ("Content-Type".to_owned(), "application/json".to_owned()),
            ("Content-Encoding".to_owned(), "gzip".to_owned()),
        ]
    }

    fn settle(&self, store: &Store, batch: &Batch, answer: &Answer) -> Result<Outcome> {
        let (outcome, status) = (Outcome::of(answer.status), answer.status);
        let events = batch.bodies.len();
        match outcome {
            Outcome::Delivered => self.leave_queue(store, batch)?,
            Outcome::Refused => {
                log::warn!("ClickMan dropped {events} events refused with status {status}");
                self.leave_queue(store, batch)?;
            }
            Outcome::Retry => self.back_off(answer, events),
        }
        Ok(outcome)
    }

    /// The batch leaves the queue, which ends any run of failures.
    fn leave_queue(&self, store: &Store, batch: &Batch) -> Result<()> {
        store.write(|transaction| batch::remove(transaction, batch))?;
        self.state.lock().backoff = Backoff::Clear;
        Ok(())
    }

    fn back_off(&self, answer: &Answer, events: usize) {
        let mut state = self.state.lock();
        let failures = match state.backoff {
            Backoff::Clear => 1,
            Backoff::Waiting { failures, .. } => failures.saturating_add(1),
        };
        let delay = backoff::delay(failures, answer.retry_after, (self.random)());
        let until = unix_millis((self.clock)()).saturating_add(millis(delay));
        state.backoff = Backoff::Waiting { failures, until };
        drop(state);
        let status = answer.status;
        log::info!("ClickMan retries {events} events in {delay:?} after status {status}");
    }
}
