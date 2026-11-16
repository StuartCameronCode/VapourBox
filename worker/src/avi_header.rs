//! An AVI output's AAC block size, put right after the encode (task #41).
//!
//! avienc declares AAC's `nBlockAlign` as `768 × channels` (riffenc: "maximum
//! bytes per frame", the spec's 6144 bits per channel) and stores AAC as VBR
//! audio (`strh.dwSampleSize` 0, one packet per chunk). Readers time such a
//! chunk as `ceil(size / nBlockAlign)` packets: ffmpeg's avidec
//! (`dshow_block_align`), VLC and DirectShow's AVI Splitter
//! (docs/reports/issue-41-aac-avi-block-align).
//!
//! ffmpeg's AAC encoder overshoots that size at 192 kbps per channel and more
//! (mono at High and Very High; mono at 160 kbps at 32 kHz; up to 866 bytes
//! measured), and no encoder option stops it. Each such packet was then timed
//! as two, so everything after it played one packet (21.3 ms at 48 kHz) later:
//! 320 ms by the end of 12 s at 256 kbps. A copied AAC stream gets the same
//! header, so Passthrough was affected too.
//!
//! The fix sets `nBlockAlign` to the stream's largest chunk, which avienc's
//! trailer has already written into the same header as
//! `strh.dwSuggestedBufferSize`. It reads the header, writes two bytes per
//! stream, and only when a chunk is over the declared size: every other file
//! is left byte for byte. Only AAC (`wFormatTag` 0x00FF): MP3's 1152 is a
//! convention readers depend on, and MP3 and AC-3 stay within theirs at every
//! setting the app offers.
//!
//! It must run after anything that writes the AVI. Nothing does after the
//! encode today: the subtitle mux only embeds into MP4/MOV/MKV (an AVI keeps
//! its SRT beside it). A later remux of an AVI would need this again.

use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use crate::models::{AudioMode, AudioPacketTiming, VideoJob};

/// AAC's `wFormatTag` as avienc writes it (`WAVE_FORMAT_RAW_AAC1`).
pub const WAVE_FORMAT_AAC: u16 = 0x00FF;

/// How much of the file holds the header list (`hdrl`). avienc reserves room
/// for its OpenDML super indexes there, a few KB per stream.
const HEADER_BYTES: u64 = 1 << 20;

/// One stream's `nBlockAlign` raised to its largest chunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockAlignFix {
    /// The stream's index in the file (video streams counted).
    pub stream: usize,
    /// Byte offset of the `nBlockAlign` field in the file.
    pub offset: u64,
    pub from: u16,
    pub to: u16,
}

impl BlockAlignFix {
    /// The job log's line for this fix.
    pub fn note(&self) -> String {
        format!(
            "AAC audio (stream {}): a packet of {} bytes is larger than AVI's declared block size of {} \
             bytes, which players would time as two packets; the block size is set to {} so every \
             packet plays at its own time",
            self.stream, self.to, self.from, self.to
        )
    }
}

/// Whether the encode's output gets [`fix_aac_block_align`]: a container whose
/// players time VBR audio by `nBlockAlign` (AVI; the table's
/// `audioPacketTiming`) with sound, whether copied or converted.
pub fn checks_block_align(job: &VideoJob) -> bool {
    job.encoding_settings.container.traits().audio_packet_timing == AudioPacketTiming::BlockAlign
        && job.encoding_settings.audio_mode != AudioMode::None
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// The chunks in `data[start..end]`: (fourcc, data offset, data size), the
/// size clipped to what is there.
fn chunks(data: &[u8], start: usize, end: usize) -> Vec<(&[u8], usize, usize)> {
    let end = end.min(data.len());
    let mut out = Vec::new();
    let mut i = start;
    while i + 8 <= end {
        let Some(size) = u32_at(data, i + 4) else { break };
        let size = size as usize;
        out.push((&data[i..i + 4], i + 8, size.min(end - i - 8)));
        match i.checked_add(8 + size + (size & 1)) {
            Some(next) => i = next,
            None => break,
        }
    }
    out
}

fn is_list(data: &[u8], c: &[u8], off: usize, size: usize, kind: &[u8; 4]) -> bool {
    c == b"LIST" && size >= 4 && data.get(off..off + 4) == Some(kind.as_slice())
}

/// The fixes an AVI's header needs, read from its first bytes: one per AAC
/// stream stored as VBR whose largest chunk (`dwSuggestedBufferSize`) is over
/// its `nBlockAlign`. Walks the RIFF lists (`RIFF AVI ` → `hdrl` → `strl` →
/// `strh` / `strf`), never searching the bytes; anything malformed, truncated
/// or not an AVI gives none.
pub fn aac_block_align_fixes(header: &[u8]) -> Vec<BlockAlignFix> {
    let mut fixes = Vec::new();
    if header.len() < 12 || &header[..4] != b"RIFF" || &header[8..12] != b"AVI " {
        return fixes;
    }
    for (c, off, size) in chunks(header, 12, header.len()) {
        if !is_list(header, c, off, size, b"hdrl") {
            continue;
        }
        let mut stream = 0;
        for (c2, off2, size2) in chunks(header, off + 4, off + size) {
            if !is_list(header, c2, off2, size2, b"strl") {
                continue;
            }
            let (mut strh, mut strf) = (None, None);
            for (c3, off3, size3) in chunks(header, off2 + 4, off2 + size2) {
                match c3 {
                    b"strh" if size3 >= 48 => strh = Some(off3),
                    b"strf" if size3 >= 14 => strf = Some(off3),
                    _ => {}
                }
            }
            if let (Some(h), Some(f)) = (strh, strf) {
                if let Some(fix) = stream_fix(header, stream, h, f) {
                    fixes.push(fix);
                }
            }
            stream += 1;
        }
    }
    fixes
}

/// The fix for one stream, given its `strh` and `strf` data offsets.
fn stream_fix(header: &[u8], stream: usize, strh: usize, strf: usize) -> Option<BlockAlignFix> {
    // strh: fccType, fccHandler, dwFlags, wPriority, wLanguage,
    // dwInitialFrames, dwScale, dwRate, dwStart, dwLength,
    // dwSuggestedBufferSize (36), dwQuality, dwSampleSize (44).
    if header.get(strh..strh + 4) != Some(b"auds".as_slice()) {
        return None;
    }
    let largest = u32_at(header, strh + 36)?;
    let sample_size = u32_at(header, strh + 44)?;
    // strf (WAVEFORMATEX): wFormatTag, nChannels, nSamplesPerSec,
    // nAvgBytesPerSec, nBlockAlign (12).
    let tag = u16_at(header, strf)?;
    let block_align = u16_at(header, strf + 12)?;
    if tag != WAVE_FORMAT_AAC || sample_size != 0 || largest <= block_align as u32 || largest > u16::MAX as u32 {
        return None;
    }
    Some(BlockAlignFix { stream, offset: (strf + 12) as u64, from: block_align, to: largest as u16 })
}

/// Applies [`aac_block_align_fixes`] to the AVI at `path`, in place. Opens it
/// for writing only when there is something to fix.
pub fn fix_aac_block_align(path: &Path) -> Result<Vec<BlockAlignFix>> {
    let mut header = Vec::new();
    std::fs::File::open(path)
        .with_context(|| format!("Failed to open {}", path.display()))?
        .take(HEADER_BYTES)
        .read_to_end(&mut header)
        .with_context(|| format!("Failed to read the header of {}", path.display()))?;
    let fixes = aac_block_align_fixes(&header);
    if !fixes.is_empty() {
        let mut f = OpenOptions::new()
            .write(true)
            .open(path)
            .with_context(|| format!("Failed to open {} for writing", path.display()))?;
        for fix in &fixes {
            f.seek(SeekFrom::Start(fix.offset))?;
            f.write_all(&fix.to.to_le_bytes())?;
        }
        f.flush()?;
    }
    Ok(fixes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ContainerFormat;

    fn chunk(fourcc: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = fourcc.to_vec();
        out.extend((body.len() as u32).to_le_bytes());
        out.extend(body);
        if body.len() % 2 == 1 {
            out.push(0);
        }
        out
    }

    fn list(kind: &[u8; 4], parts: &[Vec<u8>]) -> Vec<u8> {
        let mut body = kind.to_vec();
        for p in parts {
            body.extend(p);
        }
        chunk(b"LIST", &body)
    }

    /// A 56-byte strh as avienc writes it.
    fn strh(kind: &[u8; 4], suggested: u32, sample_size: u32) -> Vec<u8> {
        let mut b = kind.to_vec();
        b.extend([0u8; 4]); // fccHandler
        b.extend(0u32.to_le_bytes()); // dwFlags
        b.extend([0u8; 4]); // wPriority, wLanguage
        b.extend(0u32.to_le_bytes()); // dwInitialFrames
        b.extend(8u32.to_le_bytes()); // dwScale
        b.extend(375u32.to_le_bytes()); // dwRate
        b.extend(0u32.to_le_bytes()); // dwStart
        b.extend(564u32.to_le_bytes()); // dwLength
        b.extend(suggested.to_le_bytes());
        b.extend((-1i32).to_le_bytes()); // dwQuality
        b.extend(sample_size.to_le_bytes());
        b.extend([0u8; 8]); // rcFrame
        chunk(b"strh", &b)
    }

    fn strf_audio(tag: u16, channels: u16, block_align: u16) -> Vec<u8> {
        let mut b = tag.to_le_bytes().to_vec();
        b.extend(channels.to_le_bytes());
        b.extend(48000u32.to_le_bytes());
        b.extend(24000u32.to_le_bytes());
        b.extend(block_align.to_le_bytes());
        b.extend(0u16.to_le_bytes()); // wBitsPerSample
        b.extend(2u16.to_le_bytes()); // cbSize
        b.extend([0x11, 0x88]); // AudioSpecificConfig
        chunk(b"strf", &b)
    }

    fn video_strl() -> Vec<u8> {
        list(b"strl", &[strh(b"vids", 29020, 0), chunk(b"strf", &[0u8; 40]), chunk(b"indx", &[0u8; 24])])
    }

    fn audio_strl(tag: u16, channels: u16, block_align: u16, suggested: u32, sample_size: u32) -> Vec<u8> {
        list(
            b"strl",
            &[strh(b"auds", suggested, sample_size), strf_audio(tag, channels, block_align), chunk(b"indx", &[0u8; 24])],
        )
    }

    fn avi(strls: &[Vec<u8>]) -> Vec<u8> {
        let mut hdrl = vec![chunk(b"avih", &[0u8; 56])];
        hdrl.extend(strls.iter().cloned());
        let mut body = b"AVI ".to_vec();
        body.extend(list(b"hdrl", &hdrl));
        body.extend(chunk(b"JUNK", &[0u8; 100]));
        body.extend(list(b"movi", &[chunk(b"01wb", &[0u8; 833])]));
        chunk(b"RIFF", &body)
    }

    fn block_align_at(data: &[u8], fix: &BlockAlignFix) -> u16 {
        u16_at(data, fix.offset as usize).unwrap()
    }

    #[test]
    fn a_mono_aac_packet_over_768_raises_the_block_size_to_it() {
        let data = avi(&[audio_strl(WAVE_FORMAT_AAC, 1, 768, 777, 0)]);
        let fixes = aac_block_align_fixes(&data);
        assert_eq!(fixes.len(), 1);
        let f = fixes[0];
        assert_eq!((f.stream, f.from, f.to), (0, 768, 777));
        assert_eq!(block_align_at(&data, &f), 768, "the offset names nBlockAlign");
        assert!(f.note().contains("777") && f.note().contains("768"), "{}", f.note());
    }

    #[test]
    fn nothing_changes_when_every_packet_fits() {
        for largest in [0, 500, 767, 768] {
            assert!(aac_block_align_fixes(&avi(&[audio_strl(WAVE_FORMAT_AAC, 1, 768, largest, 0)])).is_empty());
        }
        assert!(aac_block_align_fixes(&avi(&[audio_strl(WAVE_FORMAT_AAC, 2, 1536, 1536, 0)])).is_empty());
    }

    #[test]
    fn stereo_over_1536_is_fixed_too() {
        let fixes = aac_block_align_fixes(&avi(&[audio_strl(WAVE_FORMAT_AAC, 2, 1536, 1554, 0)]));
        assert_eq!(fixes.iter().map(|f| (f.from, f.to)).collect::<Vec<_>>(), [(1536, 1554)]);
    }

    #[test]
    fn only_aac_stored_as_vbr_is_touched() {
        // MP3: nBlockAlign 1152 is the VBR-in-AVI convention; AC-3; PCM (CBR).
        for strl in [
            audio_strl(0x0055, 2, 1152, 1440, 0),
            audio_strl(0x2000, 2, 3840, 4000, 0),
            audio_strl(0x0001, 2, 4, 19200, 4),
            audio_strl(WAVE_FORMAT_AAC, 1, 768, 900, 1),
        ] {
            assert!(aac_block_align_fixes(&avi(&[strl])).is_empty());
        }
    }

    #[test]
    fn only_the_stream_that_overshoots_is_fixed() {
        let data = avi(&[
            video_strl(),
            audio_strl(WAVE_FORMAT_AAC, 2, 1536, 1400, 0),
            audio_strl(WAVE_FORMAT_AAC, 1, 768, 833, 0),
        ]);
        let fixes = aac_block_align_fixes(&data);
        assert_eq!(fixes.len(), 1);
        assert_eq!((fixes[0].stream, fixes[0].from, fixes[0].to), (2, 768, 833));
        assert_eq!(block_align_at(&data, &fixes[0]), 768);
    }

    #[test]
    fn a_largest_chunk_beyond_16_bits_is_left_alone() {
        assert!(aac_block_align_fixes(&avi(&[audio_strl(WAVE_FORMAT_AAC, 1, 768, 70000, 0)])).is_empty());
    }

    #[test]
    fn malformed_input_gives_no_fix_and_no_panic() {
        let good = avi(&[video_strl(), audio_strl(WAVE_FORMAT_AAC, 1, 768, 833, 0)]);
        assert_eq!(aac_block_align_fixes(&good).len(), 1);
        for n in 0..good.len() {
            // Truncated anywhere: never a panic, never a fix outside the bytes.
            for f in aac_block_align_fixes(&good[..n]) {
                assert!((f.offset as usize) + 2 <= n);
            }
        }
        assert!(aac_block_align_fixes(b"RIFF\x04\x00\x00\x00WAVE").is_empty());
        assert!(aac_block_align_fixes(b"not an avi at all").is_empty());
        let mut huge = good.clone();
        huge[16..20].copy_from_slice(&u32::MAX.to_le_bytes()); // hdrl's size
        let _ = aac_block_align_fixes(&huge);
    }

    #[test]
    fn the_fix_writes_exactly_two_bytes_and_nothing_when_unneeded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.avi");
        let before = avi(&[video_strl(), audio_strl(WAVE_FORMAT_AAC, 1, 768, 833, 0)]);
        std::fs::write(&path, &before).unwrap();
        let fixes = fix_aac_block_align(&path).unwrap();
        assert_eq!(fixes.len(), 1);
        let after = std::fs::read(&path).unwrap();
        assert_eq!(after.len(), before.len());
        let changed: Vec<usize> = (0..after.len()).filter(|&i| after[i] != before[i]).collect();
        let at = fixes[0].offset as usize;
        assert_eq!(changed, [at], "833 = 0x0341 differs from 768 = 0x0300 in its low byte only");
        assert_eq!(block_align_at(&after, &fixes[0]), 833);
        // Run again: nothing left to do.
        assert!(fix_aac_block_align(&path).unwrap().is_empty());

        let fine = avi(&[audio_strl(WAVE_FORMAT_AAC, 1, 768, 760, 0)]);
        std::fs::write(&path, &fine).unwrap();
        let mtime = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert!(fix_aac_block_align(&path).unwrap().is_empty());
        assert_eq!(std::fs::read(&path).unwrap(), fine);
        assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), mtime);
    }

    #[test]
    fn checked_for_every_avi_with_sound_and_nothing_else() {
        for container in [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            for mode in [AudioMode::Passthrough, AudioMode::Convert, AudioMode::None] {
                let mut job: VideoJob = serde_json::from_value(serde_json::json!({
                    "id": "00000000-0000-0000-0000-000000000041",
                    "inputPath": "in.mkv",
                    "outputPath": "out.avi",
                    "qtgmcParameters": {},
                    "encodingSettings": {},
                }))
                .unwrap();
                job.encoding_settings.container = container;
                job.encoding_settings.audio_mode = mode;
                assert_eq!(
                    checks_block_align(&job),
                    container == ContainerFormat::Avi && mode != AudioMode::None,
                    "{container:?} {mode:?}"
                );
            }
        }
    }
}
