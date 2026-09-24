use serde::Serialize;
use serde_json::{Map, Value};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use crate::flatten::flatten;
use crate::sanitize::Sanitizer;

/// The limits of docs/PROTOCOL.md. Only the age limit is a server setting; the
/// rest are part of the protocol and change with its version.
#[derive(Debug, Clone)]
pub struct Limits {
    pub max_events: usize,
    pub max_event_age: Duration,
    pub max_future: Duration,
    pub max_property_keys: usize,
    pub max_context_keys: usize,
    pub max_key_chars: usize,
    pub max_event_chars: usize,
    pub max_external_id_chars: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_events: 500,
            max_event_age: Duration::days(90),
            max_future: Duration::hours(1),
            max_property_keys: 128,
            max_context_keys: 64,
            max_key_chars: 128,
            max_event_chars: 200,
            max_external_id_chars: 256,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    UnsupportedType,
    InvalidMessageId,
    InvalidEvent,
    InvalidExternalId,
    InvalidTimestamp,
    TimestampOutOfRange,
    InvalidProperties,
    InvalidContext,
    TooManyKeys,
}

/// An accepted event: validated, clock-corrected, flattened and sanitized.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub message_id: Uuid,
    pub event: String,
    pub external_id: String,
    pub occurred_at: OffsetDateTime,
    pub properties: Map<String, Value>,
    pub context: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Rejection {
    pub index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub reason: Reason,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Normalized {
    pub events: Vec<Event>,
    pub rejected: Vec<Rejection>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BatchError {
    #[error("malformed batch: {0}")]
    Malformed(String),
}

/// Validates a batch body per docs/PROTOCOL.md. A batch that cannot be read at
/// all is refused as a whole; an invalid event is rejected alone.
pub fn normalize(
    body: &[u8],
    received_at: OffsetDateTime,
    sanitizer: &Sanitizer,
    limits: &Limits,
) -> Result<Normalized, BatchError> {
    let root: Value = serde_json::from_slice(body)
        .map_err(|error| malformed(format!("the body is not JSON: {error}")))?;
    let root = root
        .as_object()
        .ok_or_else(|| malformed("the body is not a JSON object"))?;

    let sent_at = root
        .get("sentAt")
        .and_then(Value::as_str)
        .and_then(parse_time)
        .ok_or_else(|| malformed("sentAt is missing or not an RFC 3339 time"))?;

    let items = root
        .get("batch")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("batch is missing or not an array"))?;
    if items.is_empty() || items.len() > limits.max_events {
        return Err(malformed(format!(
            "batch must hold 1 to {} events",
            limits.max_events
        )));
    }

    let batch_context = match root.get("context") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(context)) => context.clone(),
        Some(_) => return Err(malformed("context is not an object")),
    };

    let skew = received_at - sent_at;
    let mut normalized = Normalized {
        events: Vec::with_capacity(items.len()),
        rejected: Vec::new(),
    };

    for (index, item) in items.iter().enumerate() {
        match normalize_event(item, &batch_context, skew, received_at, sanitizer, limits) {
            Ok(event) => normalized.events.push(event),
            Err(reason) => normalized.rejected.push(Rejection {
                index,
                message_id: item
                    .get("messageId")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                reason,
            }),
        }
    }

    Ok(normalized)
}

fn normalize_event(
    item: &Value,
    batch_context: &Map<String, Value>,
    skew: Duration,
    received_at: OffsetDateTime,
    sanitizer: &Sanitizer,
    limits: &Limits,
) -> Result<Event, Reason> {
    let item = item.as_object().ok_or(Reason::InvalidEvent)?;

    if item.get("type").and_then(Value::as_str) != Some("track") {
        return Err(Reason::UnsupportedType);
    }

    let message_id = item
        .get("messageId")
        .and_then(Value::as_str)
        .and_then(|text| Uuid::parse_str(text).ok())
        .ok_or(Reason::InvalidMessageId)?;

    let event = text_field(item, "event", limits.max_event_chars).ok_or(Reason::InvalidEvent)?;
    let external_id = text_field(item, "externalId", limits.max_external_id_chars)
        .ok_or(Reason::InvalidExternalId)?;

    let timestamp = item
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_time)
        .ok_or(Reason::InvalidTimestamp)?;
    let occurred_at = timestamp + skew;
    if occurred_at > received_at + limits.max_future
        || occurred_at < received_at - limits.max_event_age
    {
        return Err(Reason::TimestampOutOfRange);
    }

    let mut properties = match item.get("properties") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(properties)) => flatten(properties),
        Some(_) => return Err(Reason::InvalidProperties),
    };
    check_keys(
        &properties,
        limits.max_property_keys,
        limits.max_key_chars,
        Reason::InvalidProperties,
    )?;

    let mut merged = batch_context.clone();
    match item.get("context") {
        None | Some(Value::Null) => {}
        Some(Value::Object(own)) => deep_merge(&mut merged, own),
        Some(_) => return Err(Reason::InvalidContext),
    }
    let mut context = flatten(&merged);
    check_keys(
        &context,
        limits.max_context_keys,
        limits.max_key_chars,
        Reason::InvalidContext,
    )?;

    sanitizer.sanitize(&mut properties);
    sanitizer.sanitize(&mut context);

    Ok(Event {
        message_id,
        event,
        external_id,
        occurred_at,
        properties,
        context,
    })
}

fn text_field(item: &Map<String, Value>, name: &str, max_chars: usize) -> Option<String> {
    let text = item.get(name)?.as_str()?;
    let chars = text.chars().count();

    (chars > 0 && chars <= max_chars && !text.chars().any(char::is_control))
        .then(|| text.to_owned())
}

fn check_keys(
    flat: &Map<String, Value>,
    max_keys: usize,
    max_key_chars: usize,
    invalid: Reason,
) -> Result<(), Reason> {
    if flat.len() > max_keys {
        return Err(Reason::TooManyKeys);
    }
    if flat
        .keys()
        .any(|key| key.is_empty() || key.chars().count() > max_key_chars)
    {
        return Err(invalid);
    }
    Ok(())
}

/// Merges `over` into `base`, recursing into objects present on both sides.
fn deep_merge(base: &mut Map<String, Value>, over: &Map<String, Value>) {
    for (key, value) in over {
        match (base.get_mut(key), value) {
            (Some(Value::Object(inner)), Value::Object(value)) => deep_merge(inner, value),
            _ => {
                base.insert(key.clone(), value.clone());
            }
        }
    }
}

fn parse_time(text: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(text, &Rfc3339).ok()
}

fn malformed(message: impl Into<String>) -> BatchError {
    BatchError::Malformed(message.into())
}
