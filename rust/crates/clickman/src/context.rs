use serde_json::{Map, Value, json};

pub(crate) const LIBRARY_NAME: &str = "clickman-rust";

/// The host's standard context with this library's name and version.
pub(crate) fn standard(mut host: Map<String, Value>) -> Map<String, Value> {
    host.insert(
        "library".to_owned(),
        json!({"name": LIBRARY_NAME, "version": env!("CARGO_PKG_VERSION")}),
    );
    host
}

/// The context an event carries: the standard one, with the traits when there are any.
pub(crate) fn with_traits(
    standard: &Map<String, Value>,
    traits: Map<String, Value>,
) -> Map<String, Value> {
    let mut context = standard.clone();
    if !traits.is_empty() {
        context.insert("traits".to_owned(), Value::Object(traits));
    }
    context
}
