use std::path::PathBuf;

use clickman_protocol::{Sanitizer, flatten};
use serde_json::{Map, Value};

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).unwrap()
}

fn object(value: &Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn flatten_matches_the_shared_fixtures() {
    let fixture = fixture("flatten.json");

    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();

        assert_eq!(
            flatten(&object(&case["input"])),
            object(&case["output"]),
            "{name}"
        );
    }
}

#[test]
fn sanitize_matches_the_shared_fixtures() {
    let fixture = fixture("sanitize.json");
    let fragments: Vec<String> = fixture["fragments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|fragment| fragment.as_str().unwrap().to_owned())
        .collect();
    let sanitizer = Sanitizer::new(&fragments);

    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut input = object(&case["input"]);

        sanitizer.sanitize(&mut input);

        assert_eq!(input, object(&case["output"]), "{name}");
    }
}

#[test]
fn the_default_fragments_are_the_documented_ones() {
    let fixture = fixture("sanitize.json");
    let documented: Vec<&str> = fixture["fragments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|fragment| fragment.as_str().unwrap())
        .collect();

    assert_eq!(clickman_protocol::DEFAULT_FRAGMENTS, documented.as_slice());
}
