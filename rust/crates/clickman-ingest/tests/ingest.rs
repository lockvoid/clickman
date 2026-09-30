mod support;

use axum::http::StatusCode;
use clickman_ingest::{AppState, SettingsCell, router};
use serde_json::json;
use support::*;
use time::Duration;
use uuid::Uuid;

/// Runs each scenario against PostgreSQL and against SQLite.
macro_rules! on_every_database {
    ($($scenario:ident),* $(,)?) => {
        $(
            mod $scenario {
                #[tokio::test]
                async fn postgres() {
                    super::$scenario(super::TestDatabase::postgres().await).await;
                }

                #[tokio::test]
                async fn sqlite() {
                    super::$scenario(super::TestDatabase::sqlite().await).await;
                }
            }
        )*
    };
}

on_every_database!(
    a_gzipped_batch_is_stored_flattened_and_sanitized,
    a_plain_batch_is_accepted_too,
    the_client_clock_is_corrected_by_the_sent_at_skew,
    a_replayed_batch_counts_duplicates_and_stores_nothing_twice,
    invalid_events_are_rejected_one_by_one_and_the_rest_are_stored,
    a_malformed_batch_is_refused,
    a_missing_or_unknown_write_key_is_refused,
    an_unsupported_encoding_is_refused,
    bodies_over_the_wire_or_the_decompressed_limit_are_refused,
    a_client_over_its_rate_is_told_when_to_come_back,
    published_settings_take_effect_on_reload,
    the_health_check_answers,
    the_schema_check_names_what_is_missing,
);

async fn app(database: &TestDatabase) -> axum::Router {
    let settings = SettingsCell::load(&database.database).await.unwrap();
    router(AppState::new(database.database.clone(), settings))
}

async fn start(database: TestDatabase) -> (TestDatabase, axum::Router) {
    database.publish_settings(default_settings()).await;
    let router = app(&database).await;
    (database, router)
}

async fn a_gzipped_batch_is_stored_flattened_and_sanitized(database: TestDatabase) {
    let (database, router) = start(database).await;
    let message_id = Uuid::now_v7();
    let body = serde_json::to_vec(&batch(vec![event(
        message_id,
        json!({
            "properties": { "format": "mp4", "user": { "email": "a@b.co" } },
            "context": { "os": { "name": "iOS" } },
        }),
    )]))
    .unwrap();

    let response = post(&router, gzip(&body), &[AUTHORIZATION, GZIP]).await;

    assert_eq!(response.status, StatusCode::ACCEPTED);
    assert_eq!(
        response.json,
        json!({ "accepted": 1, "duplicates": 0, "rejected": [] })
    );

    let rows = database.stored().await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].message_id, message_id);
    assert_eq!(rows[0].event, "export_completed");
    assert_eq!(rows[0].external_id, "user_42");
    assert_eq!(
        rows[0].properties,
        json!({ "format": "mp4", "user.email": "[FILTERED]" })
    );
    assert_eq!(rows[0].context, json!({ "os.name": "iOS" }));
}

async fn a_plain_batch_is_accepted_too(database: TestDatabase) {
    let (database, router) = start(database).await;
    let body = serde_json::to_vec(&batch(vec![event(Uuid::now_v7(), json!({}))])).unwrap();

    let response = post(&router, body, &[AUTHORIZATION]).await;

    assert_eq!(response.status, StatusCode::ACCEPTED);
    assert_eq!(database.stored().await.len(), 1);
}

async fn the_client_clock_is_corrected_by_the_sent_at_skew(database: TestDatabase) {
    let (database, router) = start(database).await;
    let client_now = now() - Duration::hours(3);
    let body = serde_json::to_vec(&json!({
        "sentAt": rfc3339(client_now),
        "batch": [event(Uuid::now_v7(), json!({ "timestamp": rfc3339(client_now - Duration::minutes(10)) }))],
    }))
    .unwrap();

    post(&router, body, &[AUTHORIZATION]).await;

    let occurred_at = database.stored().await[0].occurred_at;
    let expected = now() - Duration::minutes(10);
    assert!(
        (occurred_at - expected).abs() < Duration::seconds(5),
        "{occurred_at} is not near {expected}"
    );
}

async fn a_replayed_batch_counts_duplicates_and_stores_nothing_twice(database: TestDatabase) {
    let (database, router) = start(database).await;
    let body = serde_json::to_vec(&batch(vec![
        event(Uuid::now_v7(), json!({})),
        event(Uuid::now_v7(), json!({})),
    ]))
    .unwrap();

    post(&router, body.clone(), &[AUTHORIZATION]).await;
    let replay = post(&router, body, &[AUTHORIZATION]).await;

    assert_eq!(replay.status, StatusCode::ACCEPTED);
    assert_eq!(
        replay.json,
        json!({ "accepted": 0, "duplicates": 2, "rejected": [] })
    );
    assert_eq!(database.stored().await.len(), 2);
}

async fn invalid_events_are_rejected_one_by_one_and_the_rest_are_stored(database: TestDatabase) {
    let (database, router) = start(database).await;
    let bad = Uuid::now_v7();
    let body = serde_json::to_vec(&batch(vec![
        event(bad, json!({ "event": "" })),
        event(Uuid::now_v7(), json!({})),
    ]))
    .unwrap();

    let response = post(&router, body, &[AUTHORIZATION]).await;

    assert_eq!(response.status, StatusCode::ACCEPTED);
    assert_eq!(
        response.json,
        json!({
            "accepted": 1,
            "duplicates": 0,
            "rejected": [{ "index": 0, "messageId": bad.to_string(), "reason": "invalid_event" }],
        })
    );
    assert_eq!(database.stored().await.len(), 1);
}

async fn a_malformed_batch_is_refused(database: TestDatabase) {
    let (database, router) = start(database).await;

    let response = post(&router, b"{\"batch\": []}".to_vec(), &[AUTHORIZATION]).await;

    assert_eq!(response.status, StatusCode::BAD_REQUEST);
    assert_eq!(response.json["error"], "malformed_batch");
    assert!(database.stored().await.is_empty());
}

async fn a_missing_or_unknown_write_key_is_refused(database: TestDatabase) {
    let (database, router) = start(database).await;
    let body = serde_json::to_vec(&batch(vec![event(Uuid::now_v7(), json!({}))])).unwrap();

    let missing = post(&router, body.clone(), &[]).await;
    let unknown = post(
        &router,
        body.clone(),
        &[("authorization", "Bearer someone-else")],
    )
    .await;
    let malformed = post(&router, body, &[("authorization", "test-write-key")]).await;

    for response in [missing, unknown, malformed] {
        assert_eq!(response.status, StatusCode::UNAUTHORIZED);
        assert_eq!(response.json, json!({ "error": "invalid_write_key" }));
    }
    assert!(database.stored().await.is_empty());
}

async fn an_unsupported_encoding_is_refused(database: TestDatabase) {
    let (_database, router) = start(database).await;
    let body = serde_json::to_vec(&batch(vec![event(Uuid::now_v7(), json!({}))])).unwrap();

    let response = post(&router, body, &[AUTHORIZATION, ("content-encoding", "br")]).await;

    assert_eq!(response.status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(response.json, json!({ "error": "unsupported_encoding" }));
}

async fn bodies_over_the_wire_or_the_decompressed_limit_are_refused(database: TestDatabase) {
    let (_database, router) = start(database).await;
    let over_wire = vec![b' '; clickman_ingest::MAX_WIRE_BYTES + 1];
    let bomb = gzip(&vec![b' '; clickman_ingest::MAX_DECOMPRESSED_BYTES + 1]);

    let wire = post(&router, over_wire, &[AUTHORIZATION]).await;
    let decompressed = post(&router, bomb, &[AUTHORIZATION, GZIP]).await;

    for response in [wire, decompressed] {
        assert_eq!(response.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(response.json, json!({ "error": "batch_too_large" }));
    }
}

async fn a_client_over_its_rate_is_told_when_to_come_back(database: TestDatabase) {
    let mut settings = default_settings();
    settings["rateLimit"] = json!({ "perSecond": 1, "burst": 2 });
    database.publish_settings(settings).await;
    let router = app(&database).await;
    let body = serde_json::to_vec(&batch(vec![event(Uuid::now_v7(), json!({}))])).unwrap();
    let client = ("x-forwarded-for", "203.0.113.7, 10.0.0.1");
    let other_client = ("x-forwarded-for", "198.51.100.9");

    let first = post(&router, body.clone(), &[AUTHORIZATION, client]).await;
    let second = post(&router, body.clone(), &[AUTHORIZATION, client]).await;
    let third = post(&router, body.clone(), &[AUTHORIZATION, client]).await;
    let other = post(&router, body, &[AUTHORIZATION, other_client]).await;

    assert_eq!(first.status, StatusCode::ACCEPTED);
    assert_eq!(second.status, StatusCode::ACCEPTED);
    assert_eq!(third.status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(third.json, json!({ "error": "rate_limited" }));
    assert_eq!(third.headers["retry-after"], "1");
    assert_eq!(other.status, StatusCode::ACCEPTED);
}

async fn published_settings_take_effect_on_reload(database: TestDatabase) {
    let settings = SettingsCell::load(&database.database).await.unwrap();
    let router = router(AppState::new(database.database.clone(), settings.clone()));
    let body = serde_json::to_vec(&batch(vec![event(Uuid::now_v7(), json!({}))])).unwrap();

    let before = post(&router, body.clone(), &[AUTHORIZATION]).await;
    database.publish_settings(default_settings()).await;
    settings.reload(&database.database).await.unwrap();
    let after = post(&router, body, &[AUTHORIZATION]).await;

    assert_eq!(before.status, StatusCode::UNAUTHORIZED);
    assert_eq!(after.status, StatusCode::ACCEPTED);
}

async fn the_health_check_answers(database: TestDatabase) {
    let (_database, router) = start(database).await;

    let response = tower::ServiceExt::oneshot(
        router,
        axum::http::Request::get("/health")
            .body(axum::body::Body::empty())
            .unwrap(),
    )
    .await
    .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

async fn the_schema_check_names_what_is_missing(database: TestDatabase) {
    database.drop_table("clickman_settings").await;

    let error = clickman_ingest::verify_schema(&database.database)
        .await
        .unwrap_err();

    assert!(error.to_string().contains("clickman_settings"), "{error}");
}
