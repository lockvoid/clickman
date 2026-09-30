use std::io::Read;

use flate2::read::GzDecoder;

use crate::gzip::compress;

fn inflate(data: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    GzDecoder::new(data).read_to_end(&mut output).unwrap();
    output
}

#[test]
fn compress_writes_a_gzip_member_any_reader_inflates() {
    let text = r#"{"type":"track","event":"export_completed"}"#.repeat(100);
    let zipped = compress(text.as_bytes()).unwrap();
    assert_eq!(&zipped[..2], &[0x1f, 0x8b]);
    assert!(zipped.len() < text.len() / 5);
    assert_eq!(inflate(&zipped), text.as_bytes());
}

#[test]
fn empty_input_is_still_a_gzip_member() {
    let zipped = compress(&[]).unwrap();
    assert_eq!(&zipped[..2], &[0x1f, 0x8b]);
    assert!(inflate(&zipped).is_empty());
}
