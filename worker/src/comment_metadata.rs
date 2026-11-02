//! The output's `comment` tag: the source's comment, prefixed with the
//! VapourBox version, handed to ffmpeg in a file rather than on its command line.
//!
//! A comment is source data of any length. AI video tools store their whole
//! workflow there (tens of KB of JSON), and as `-metadata comment=…` that took
//! the encoder's command line past Windows' 32,767-character limit: ffmpeg
//! could not even be started (issue #138). An FFMETADATA file has no limit, and
//! keeps the command line the same length whatever the source carries.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

/// Read the source's container-level comment, exactly as stored.
///
/// Read as JSON, whose escaping is exact. The `csv` writer quoted the value and
/// doubled every `"` inside, so a JSON comment came back altered and grew each
/// time an output was processed; the plain `default` writer goes through a
/// text-mode stdout on Windows, which turns each newline into `\r\n`.
pub fn probe(
    ffprobe: &Path,
    env: &std::collections::HashMap<String, String>,
    input_path: &str,
) -> Option<String> {
    let output = Command::new(ffprobe)
        .args([
            "-v", "quiet",
            "-show_entries", "format_tags=comment",
            "-of", "json",
            input_path,
        ])
        .envs(env)
        .output()
        .ok()?;
    comment_from_json(&output.stdout)
}

/// The `comment` tag from ffprobe's `-of json` output, whatever case the
/// container stored its name in.
fn comment_from_json(json: &[u8]) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(json).ok()?;
    let tags = json.get("format")?.get("tags")?.as_object()?;
    let comment = tags
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("comment"))?
        .1
        .as_str()?;
    if comment.trim().is_empty() { None } else { Some(comment.to_string()) }
}

/// The comment to write: `VapourBox <version>`, then the source's own after
/// ` | `. A source that is itself a VapourBox output (re-processing it, or the
/// subtitle mux after an encode) keeps one prefix rather than gaining another.
pub fn output_comment(existing: Option<&str>) -> String {
    let prefix = format!("VapourBox {}", env!("CARGO_PKG_VERSION"));
    match existing.map(strip_vapourbox_prefix) {
        Some(rest) if !rest.is_empty() => format!("{} | {}", prefix, rest),
        _ => prefix,
    }
}

/// `existing` without a leading `VapourBox <version>` (and its ` | `).
fn strip_vapourbox_prefix(existing: &str) -> &str {
    let Some(rest) = existing.strip_prefix("VapourBox ") else { return existing };
    let version_end = rest.find(' ').unwrap_or(rest.len());
    let version = &rest[..version_end];
    if version.is_empty() || !version.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return existing;
    }
    let after = &rest[version_end..];
    if after.is_empty() {
        ""
    } else if let Some(tail) = after.strip_prefix(" | ") {
        tail
    } else {
        existing
    }
}

/// The FFMETADATA document carrying `comment` as the only global tag.
/// `=`, `;`, `#`, `\` and line breaks are escaped with a backslash: an
/// unescaped `\r` ends the line just as `\n` does.
pub fn ffmetadata(comment: &str) -> String {
    let mut out = String::from(";FFMETADATA1\ncomment=");
    for c in comment.chars() {
        if matches!(c, '=' | ';' | '#' | '\\' | '\n' | '\r') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('\n');
    out
}

/// The comment written to a temporary FFMETADATA file, deleted on drop. Keep
/// it alive until the ffmpeg that reads it has exited.
pub struct CommentFile {
    path: PathBuf,
}

impl CommentFile {
    /// Write `comment` to `<temp>/vb_metadata_<tag>.txt`.
    pub fn write(tag: &str, comment: &str) -> Result<Self> {
        let path = std::env::temp_dir().join(format!("vb_metadata_{}.txt", tag));
        fs::write(&path, ffmetadata(comment))
            .with_context(|| format!("Failed to write metadata file {:?}", path))?;
        Ok(Self { path })
    }

    /// The arguments that add this file as an ffmpeg input.
    pub fn input_args(&self) -> Vec<String> {
        vec![
            "-f".to_string(),
            "ffmetadata".to_string(),
            "-i".to_string(),
            self.path.to_string_lossy().to_string(),
        ]
    }

    /// `-map_metadata:g <input_index>`: take the output's global tags from
    /// this file, `input_index` being the index its `-i` has.
    ///
    /// To keep another input's other global tags as well, map that input
    /// AFTER this: ffmpeg never overwrites a tag an earlier mapping copied, so
    /// the comment comes from here and the rest from there.
    pub fn map_args(input_index: usize) -> Vec<String> {
        vec!["-map_metadata:g".to_string(), input_index.to_string()]
    }

    #[cfg(test)]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for CommentFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Undo `ffmetadata`'s escaping, the way ffmpeg's demuxer reads it.
    fn unescape(value: &str) -> String {
        let mut out = String::new();
        let mut chars = value.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                if let Some(next) = chars.next() {
                    out.push(next);
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    #[test]
    fn test_ffmetadata_escapes_reserved_characters() {
        let comment = "a=b; #c \\d\nline two \"q\", ok\r\nthree";
        let doc = ffmetadata(comment);
        assert!(doc.starts_with(";FFMETADATA1\ncomment="));
        assert!(doc.ends_with('\n'));
        let value = doc
            .strip_prefix(";FFMETADATA1\ncomment=")
            .unwrap()
            .strip_suffix('\n')
            .unwrap();
        // Exactly one logical line: the embedded newline is escaped.
        let unescaped_breaks = value.replace("\\\n", "").replace("\\\r", "");
        assert!(!unescaped_breaks.contains(['\n', '\r']));
        assert_eq!(unescape(value), comment);
    }

    /// Issue #138 on Windows: the comment is read from JSON, so a newline in
    /// it is a newline, never a text-mode `\r\n`.
    #[test]
    fn test_comment_is_read_from_json_exactly() {
        let json = br#"{"format": {"tags": {"COMMENT": "a\nb \"c\", d"}}}"#;
        assert_eq!(comment_from_json(json).as_deref(), Some("a\nb \"c\", d"));
        assert_eq!(comment_from_json(br#"{"format": {"tags": {"title": "x"}}}"#), None);
        assert_eq!(comment_from_json(br#"{"format": {}}"#), None);
        assert_eq!(comment_from_json(b"not json"), None);
    }

    #[test]
    fn test_output_comment_prefixes_the_version() {
        let v = env!("CARGO_PKG_VERSION");
        assert_eq!(output_comment(None), format!("VapourBox {v}"));
        assert_eq!(output_comment(Some("hello")), format!("VapourBox {v} | hello"));
    }

    #[test]
    fn test_output_comment_does_not_stack_prefixes() {
        let v = env!("CARGO_PKG_VERSION");
        assert_eq!(output_comment(Some("VapourBox 1.2.0")), format!("VapourBox {v}"));
        assert_eq!(
            output_comment(Some("VapourBox 1.2.0 | {\"a\": 1}")),
            format!("VapourBox {v} | {{\"a\": 1}}")
        );
        // Text that merely starts with the name is the user's own.
        assert_eq!(
            output_comment(Some("VapourBox rocks")),
            format!("VapourBox {v} | VapourBox rocks")
        );
    }

    /// Issue #138: the arguments do not grow with the comment.
    #[test]
    fn test_arguments_do_not_carry_the_comment() {
        let huge = "x".repeat(200_000);
        let file = CommentFile::write("test_138_args", &output_comment(Some(&huge))).unwrap();
        let args: usize = file
            .input_args()
            .iter()
            .chain(CommentFile::map_args(2).iter())
            .map(|a| a.len())
            .sum();
        assert!(args < 1_000, "{args} characters of arguments");
        let written = fs::read_to_string(file.path()).unwrap();
        assert!(written.contains(&huge));
        let path = file.path().to_path_buf();
        drop(file);
        assert!(!path.exists(), "the file is removed on drop");
    }
}
