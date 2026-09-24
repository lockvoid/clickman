use std::ffi::{CStr, CString};
use std::io::Read;

use clickman_core::capi::*;
use flate2::read::GzDecoder;
use serde_json::Value;

fn last_error() -> String {
    unsafe { CStr::from_ptr(clickman_last_error()) }
        .to_string_lossy()
        .into_owned()
}

fn now_ms() -> i64 {
    (time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000) as i64
}

struct Path(CString, std::path::PathBuf);

impl Path {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("clickman-capi-{}.sqlite", uuid::Uuid::now_v7()));
        Self(CString::new(path.to_str().unwrap()).unwrap(), path)
    }
}

impl Drop for Path {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.1.display()));
        }
    }
}

#[test]
fn a_batch_round_trips_through_the_c_boundary() {
    let path = Path::new();
    let config = CString::new(r#"{"flushAt": 1}"#).unwrap();
    let external_id = CString::new("user_42").unwrap();
    let context = CString::new(r#"{"os": {"name": "iOS"}}"#).unwrap();
    let event = CString::new("export_completed").unwrap();
    let properties = CString::new(r#"{"format": "mp4"}"#).unwrap();

    unsafe {
        let client = clickman_open(path.0.as_ptr(), config.as_ptr());
        assert!(!client.is_null(), "{}", last_error());

        assert_eq!(clickman_identify(client, external_id.as_ptr()), 0);
        assert_eq!(clickman_set_context(client, context.as_ptr()), 0);
        assert_eq!(
            clickman_track(client, event.as_ptr(), properties.as_ptr(), 0),
            0
        );
        assert_eq!(clickman_pending(client), 1);

        let mut batch = clickman_batch {
            id: 0,
            events: 0,
            body: clickman_buf {
                ptr: std::ptr::null_mut(),
                len: 0,
            },
        };
        assert_eq!(clickman_take_batch(client, now_ms(), false, &mut batch), 1);
        assert_eq!(batch.events, 1);

        let body = std::slice::from_raw_parts(batch.body.ptr, batch.body.len);
        let mut json = String::new();
        GzDecoder::new(body).read_to_string(&mut json).unwrap();
        let decoded: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded["batch"][0]["event"], "export_completed");
        assert_eq!(decoded["batch"][0]["externalId"], "user_42");
        assert_eq!(decoded["batch"][0]["context"]["os"]["name"], "iOS");
        clickman_buf_free(batch.body);

        assert_eq!(
            clickman_complete_batch(client, batch.id, 202, -1, now_ms()),
            0
        );
        assert_eq!(clickman_pending(client), 0);

        let mut nothing = clickman_batch {
            id: 7,
            events: 7,
            body: clickman_buf {
                ptr: std::ptr::null_mut(),
                len: 7,
            },
        };
        assert_eq!(clickman_take_batch(client, now_ms(), true, &mut nothing), 0);
        assert_eq!((nothing.id, nothing.events, nothing.body.len), (0, 0, 0));
        assert!(nothing.body.ptr.is_null());

        clickman_close(client);
    }
}

#[test]
fn failures_are_reported_through_the_last_error() {
    let path = Path::new();
    let bad_config = CString::new(r#"{"flushAt": -1}"#).unwrap();
    let empty = CString::new("").unwrap();
    let not_json = CString::new("{").unwrap();

    unsafe {
        assert!(clickman_open(path.0.as_ptr(), bad_config.as_ptr()).is_null());
        assert!(last_error().contains("flushAt"), "{}", last_error());

        let client = clickman_open(path.0.as_ptr(), std::ptr::null());
        assert!(!client.is_null());
        assert_eq!(last_error(), "");

        assert_eq!(
            clickman_track(client, std::ptr::null(), std::ptr::null(), 0),
            -1
        );
        assert_eq!(last_error(), "event is NULL");

        assert_eq!(
            clickman_track(client, empty.as_ptr(), std::ptr::null(), 0),
            -1
        );
        assert!(
            last_error().starts_with("invalid event"),
            "{}",
            last_error()
        );

        assert_eq!(clickman_set_context(client, not_json.as_ptr()), -1);
        assert!(
            last_error().starts_with("the context is not JSON"),
            "{}",
            last_error()
        );

        assert_eq!(clickman_complete_batch(client, 1, -5, -1, now_ms()), -1);
        assert_eq!(clickman_pending(std::ptr::null()), -1);
        assert_eq!(last_error(), "the client is NULL");

        clickman_close(client);
        clickman_close(std::ptr::null_mut());
        clickman_buf_free(clickman_buf {
            ptr: std::ptr::null_mut(),
            len: 0,
        });
    }
}

#[test]
fn the_version_names_the_protocol() {
    let version = unsafe { CStr::from_ptr(clickman_version()) }
        .to_str()
        .unwrap();

    assert!(version.starts_with("clickman-core "), "{version}");
    assert!(version.ends_with("(protocol v1)"), "{version}");
}

#[test]
fn launches_and_traits_cross_the_c_boundary() {
    let path = Path::new();
    let version = CString::new("1.40").unwrap();
    let build = CString::new("140").unwrap();
    let traits = CString::new(r#"{"plan": "pro"}"#).unwrap();
    let not_an_object = CString::new("[1]").unwrap();

    unsafe {
        let client = clickman_open(path.0.as_ptr(), std::ptr::null());
        assert!(!client.is_null(), "{}", last_error());

        assert_eq!(clickman_set_traits(client, traits.as_ptr()), 0);
        assert_eq!(
            clickman_app_launched(client, version.as_ptr(), build.as_ptr(), now_ms()),
            0
        );
        assert_eq!(clickman_set_traits(client, not_an_object.as_ptr()), -1);
        assert!(last_error().contains("traits"));

        let mut batch = clickman_batch {
            id: 0,
            events: 0,
            body: clickman_buf {
                ptr: std::ptr::null_mut(),
                len: 0,
            },
        };
        assert_eq!(clickman_take_batch(client, now_ms(), true, &mut batch), 1);
        let body = std::slice::from_raw_parts(batch.body.ptr, batch.body.len).to_vec();
        clickman_buf_free(batch.body);
        clickman_close(client);

        let mut json = String::new();
        GzDecoder::new(body.as_slice())
            .read_to_string(&mut json)
            .unwrap();
        let sent: Value = serde_json::from_str(&json).unwrap();
        let events: Vec<(&str, &str)> = sent["batch"]
            .as_array()
            .unwrap()
            .iter()
            .map(|event| {
                (
                    event["event"].as_str().unwrap(),
                    event["context"]["traits"]["plan"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(events, [("app_installed", "pro"), ("app_opened", "pro")]);
    }
}
