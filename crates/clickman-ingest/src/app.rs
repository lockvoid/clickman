use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use axum::Router;
use axum::extract::{ConnectInfo, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use clickman_protocol::{BatchError, normalize};
use serde_json::json;
use time::OffsetDateTime;
use tracing::{error, warn};

use crate::Database;
use crate::body::{BodyError, MAX_WIRE_BYTES, decode};
use crate::limiter::{Decision, RateLimiter};
use crate::settings::SettingsCell;

const UNAVAILABLE_RETRY_SECONDS: u64 = 5;

#[derive(Clone)]
pub struct AppState {
    database: Database,
    settings: SettingsCell,
    limiter: Arc<RateLimiter>,
}

impl AppState {
    pub fn new(database: Database, settings: SettingsCell) -> Self {
        Self {
            database,
            settings,
            limiter: Arc::new(RateLimiter::default()),
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/batch", post(batch))
        .route("/health", get(health))
        .with_state(state)
}

async fn health() -> &'static str {
    "ok"
}

async fn batch(State(state): State<AppState>, request: Request) -> Response {
    let received_at = OffsetDateTime::now_utc();
    let settings = state.settings.current();
    let (parts, body) = request.into_parts();

    let Some(source) = bearer(&parts.headers).and_then(|key| settings.source_for(key)) else {
        return failure(StatusCode::UNAUTHORIZED, "invalid_write_key");
    };

    let client = format!("{source}:{}", client_address(&parts));
    if let Decision::Limited { retry_after } =
        state
            .limiter
            .check(&client, settings.rate_limit, Instant::now())
    {
        return with_retry_after(
            failure(StatusCode::TOO_MANY_REQUESTS, "rate_limited"),
            retry_after.as_secs(),
        );
    }

    let Ok(bytes) = axum::body::to_bytes(body, MAX_WIRE_BYTES).await else {
        return failure(StatusCode::PAYLOAD_TOO_LARGE, "batch_too_large");
    };

    let encoding = parts
        .headers
        .get(header::CONTENT_ENCODING)
        .and_then(|value| value.to_str().ok());
    let decoded = match decode(encoding, &bytes) {
        Ok(decoded) => decoded,
        Err(BodyError::TooLarge) => {
            return failure(StatusCode::PAYLOAD_TOO_LARGE, "batch_too_large");
        }
        Err(BodyError::UnsupportedEncoding) => {
            return failure(StatusCode::UNSUPPORTED_MEDIA_TYPE, "unsupported_encoding");
        }
        Err(BodyError::Malformed(message)) => return malformed(message),
    };

    let normalized = match normalize(&decoded, received_at, &settings.sanitizer, &settings.limits) {
        Ok(normalized) => normalized,
        Err(BatchError::Malformed(message)) => return malformed(message),
    };

    let inserted = match state.database.insert(&normalized.events, received_at).await {
        Ok(inserted) => inserted,
        Err(database_error) => {
            error!(%database_error, source, "could not store a batch");
            return with_retry_after(
                failure(StatusCode::SERVICE_UNAVAILABLE, "unavailable"),
                UNAVAILABLE_RETRY_SECONDS,
            );
        }
    };

    if !normalized.rejected.is_empty() {
        warn!(
            source,
            rejected = normalized.rejected.len(),
            "rejected events in a batch"
        );
    }

    let accepted = normalized.events.len() as u64;
    (
        StatusCode::ACCEPTED,
        axum::Json(json!({
            "accepted": inserted,
            "duplicates": accepted - inserted,
            "rejected": normalized.rejected,
        })),
    )
        .into_response()
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|key| !key.is_empty())
}

/// The client address: the first `X-Forwarded-For` hop set by the platform's
/// router, else the socket peer.
fn client_address(parts: &axum::http::request::Parts) -> String {
    parts
        .headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|address| !address.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            parts
                .extensions
                .get::<ConnectInfo<SocketAddr>>()
                .map(|ConnectInfo(address)| address.ip().to_string())
        })
        .unwrap_or_else(|| "unknown".to_owned())
}

fn failure(status: StatusCode, code: &str) -> Response {
    (status, axum::Json(json!({ "error": code }))).into_response()
}

fn malformed(message: String) -> Response {
    (
        StatusCode::BAD_REQUEST,
        axum::Json(json!({ "error": "malformed_batch", "message": message })),
    )
        .into_response()
}

fn with_retry_after(mut response: Response, seconds: u64) -> Response {
    response
        .headers_mut()
        .insert(header::RETRY_AFTER, HeaderValue::from(seconds.max(1)));
    response
}
