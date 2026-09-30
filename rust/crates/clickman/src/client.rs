use std::sync::Arc;

use parking_lot::Mutex;
use serde_json::{Map, Value};
use uuid::Uuid;

use crate::batch::{self, Urgency};
use crate::clock::{self, Clock};
use crate::config::Config;
use crate::context;
use crate::error::{Error, Result};
use crate::event::Recorder;
use crate::identity;
use crate::launch::{self, Release};
use crate::sender::{Random, Sender};
use crate::store::Store;
use crate::transport::HttpClient;

/// A ClickMan client: events wait in the SQLite queue at `Config::path` until
/// `send_due` or `flush` sends them.
pub struct ClickMan {
    store: Store,
    sender: Sender,
    context: Mutex<Map<String, Value>>,
    max_queue: usize,
    clock: Clock,
}

impl ClickMan {
    /// Opens the queue at `config.path`; batches go through `http`.
    pub fn open(config: Config, http: impl HttpClient + 'static) -> Result<Self> {
        Self::open_with(
            config,
            Box::new(http),
            clock::system(),
            Arc::new(fastrand::f64),
        )
    }

    pub(crate) fn open_with(
        config: Config,
        http: Box<dyn HttpClient>,
        clock: Clock,
        random: Random,
    ) -> Result<Self> {
        Ok(Self {
            store: Store::open(&config.path)?,
            context: Mutex::new(context::standard(Map::new())),
            max_queue: config.max_queue,
            sender: Sender::new(http, config, clock.clone(), random),
            clock,
        })
    }

    /// Stores an event for the current actor and returns its `messageId`. An
    /// invalid name, or properties that are not an object, store nothing.
    pub fn track(&self, event: &str, properties: Value) -> Result<Uuid> {
        let properties = object(properties, Error::InvalidProperties)?;
        self.record(|recorder| recorder.record(event, properties))
    }

    /// Makes `external_id` the actor of later events.
    pub fn identify(&self, external_id: &str) -> Result<()> {
        self.store
            .write(|transaction| identity::identify(transaction, external_id))
    }

    /// Makes later events anonymous and forgets the traits.
    pub fn reset(&self) -> Result<()> {
        self.store.write(identity::reset)
    }

    /// Merges traits into the stored ones key by key; a null value removes a trait.
    pub fn set_traits(&self, changes: Value) -> Result<()> {
        let changes = object(changes, Error::InvalidTraits)?;
        self.store
            .write(|transaction| identity::set_traits(transaction, changes))
    }

    /// Records a launch: `app_installed` or `app_updated` when the version or
    /// build is new, then `app_opened`.
    pub fn app_launched(&self, version: &str, build: &str) -> Result<()> {
        let release = Release {
            version: version.to_owned(),
            build: build.to_owned(),
        };
        self.record(|recorder| launch::record(recorder, &release))
    }

    /// Sets the host's standard context (app, device, os, locale, timezone) of
    /// later events. It lives in memory only.
    pub fn set_context(&self, context: Value) -> Result<()> {
        let host = object(context, Error::InvalidContext)?;
        *self.context.lock() = context::standard(host);
        Ok(())
    }

    /// Sends what is due; the host calls it on its own timer.
    pub async fn send_due(&self) -> Result<()> {
        self.sender.drain(&self.store, Urgency::Due).await
    }

    /// Sends everything waiting, unless a failed batch is waiting out its delay
    /// or another call has a batch in flight.
    pub async fn flush(&self) -> Result<()> {
        self.sender.drain(&self.store, Urgency::Forced).await
    }

    /// The events on the device, the one in flight included.
    pub fn pending(&self) -> Result<usize> {
        self.store.read(batch::pending)
    }

    fn record<T>(&self, work: impl FnOnce(&Recorder) -> Result<T>) -> Result<T> {
        let context = self.context.lock().clone();
        let now = (self.clock)();
        self.store.write(|transaction| {
            work(&Recorder {
                transaction,
                context: &context,
                now,
                max_queue: self.max_queue,
            })
        })
    }
}

/// The JSON object an argument must be; null stands for the empty one.
fn object(value: Value, invalid: Error) -> Result<Map<String, Value>> {
    match value {
        Value::Object(object) => Ok(object),
        Value::Null => Ok(Map::new()),
        _ => Err(invalid),
    }
}
