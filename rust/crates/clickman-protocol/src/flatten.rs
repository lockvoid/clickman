use serde_json::{Map, Value};

pub const MAX_DEPTH: usize = 5;
pub const MAX_STRING_CHARS: usize = 1024;

/// Flattens nested objects into dotted keys: arrays and objects at the fifth
/// level become compact JSON text, empty objects vanish, strings are cut to
/// [`MAX_STRING_CHARS`] characters and a later key wins a collision.
pub fn flatten(object: &Map<String, Value>) -> Map<String, Value> {
    let mut flat = Map::new();
    walk(object, None, 1, &mut flat);
    flat
}

fn walk(
    object: &Map<String, Value>,
    prefix: Option<&str>,
    depth: usize,
    flat: &mut Map<String, Value>,
) {
    for (key, value) in object {
        let path = match prefix {
            Some(prefix) => format!("{prefix}.{key}"),
            None => key.clone(),
        };

        match value {
            Value::Object(inner) if depth < MAX_DEPTH => walk(inner, Some(&path), depth + 1, flat),
            Value::Object(_) | Value::Array(_) => {
                flat.insert(path, Value::String(value.to_string()));
            }
            Value::String(text) => {
                flat.insert(path, Value::String(truncate(text)));
            }
            scalar => {
                flat.insert(path, scalar.clone());
            }
        }
    }
}

fn truncate(text: &str) -> String {
    match text.char_indices().nth(MAX_STRING_CHARS) {
        Some((end, _)) => text[..end].to_owned(),
        None => text.to_owned(),
    }
}
