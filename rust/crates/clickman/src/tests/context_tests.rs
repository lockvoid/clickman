use serde_json::{Map, Value, json};

use crate::context::{standard, with_traits};

fn map(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn library() -> Value {
    json!({"name": "clickman-rust", "version": env!("CARGO_PKG_VERSION")})
}

#[test]
fn the_standard_context_is_the_hosts_with_this_library() {
    let context = standard(map(json!({"os": {"name": "macOS"}, "locale": "ru-RU"})));
    assert_eq!(
        Value::Object(context),
        json!({"os": {"name": "macOS"}, "locale": "ru-RU", "library": library()})
    );
}

#[test]
fn the_library_is_this_one_whatever_the_host_says() {
    let context = standard(map(
        json!({"library": {"name": "someone-else", "version": "9"}}),
    ));
    assert_eq!(Value::Object(context), json!({"library": library()}));
}

#[test]
fn traits_join_the_context_only_when_there_are_some() {
    let context = standard(Map::new());
    assert_eq!(with_traits(&context, Map::new()), context);
    let traited = with_traits(&context, map(json!({"plan": "pro"})));
    assert_eq!(
        Value::Object(traited),
        json!({"library": library(), "traits": {"plan": "pro"}})
    );
}
