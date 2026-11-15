//! DVD reading: IFO parsing for title enumeration and libdvdread FFI for extraction.
//!
//! Title enumeration reads IFO files directly from the filesystem (no library needed).
//! Title extraction uses libdvdread via dynamic loading for CSS decryption support.

use std::ffi::CString;
use std::os::raw::c_char;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

use crate::models::{DvdAudioTrack, DvdChapter, DvdInfo, DvdTitle};
use crate::progress_reporter::ProgressReporter;

// ============================================================================
// CONSTANTS: DVD binary format byte offsets (from DVD-Video specification)
// ============================================================================

const DVD_BLOCK_LEN: usize = 2048;

// VMGI_MAT offsets (VIDEO_TS.IFO, first 0x400 bytes)
const VMGI_NR_OF_TITLE_SETS: usize = 0x03E;
const VMGI_TT_SRPT_SECTOR: usize = 0x0C4;

// TT_SRPT offsets (within VIDEO_TS.IFO at tt_srpt sector)
const TT_SRPT_NR_OF_TITLES: usize = 0x000;
const TT_SRPT_ENTRIES_START: usize = 0x008;
const TT_SRPT_ENTRY_SIZE: usize = 12;

// Title entry offsets (within each 12-byte TT_SRPT entry)
const TITLE_NR_OF_ANGLES: usize = 0x01;
const TITLE_NR_OF_PTTS: usize = 0x02;
const TITLE_SET_NR: usize = 0x06;
const TITLE_VTS_TTN: usize = 0x07;

// VTSI_MAT offsets (VTS_XX_0.IFO, first 0x400 bytes)
const VTSI_VTS_PTT_SRPT_SECTOR: usize = 0x0C8;
const VTSI_VTS_PGCIT_SECTOR: usize = 0x0CC;
const VTSI_VTS_VIDEO_ATTR: usize = 0x200;
const VTSI_NR_OF_VTS_AUDIO: usize = 0x203;
const VTSI_VTS_AUDIO_ATTR: usize = 0x204;
const AUDIO_ATTR_SIZE: usize = 8;

// PGCIT offsets
const PGCIT_NR_OF_PGCI_SRP: usize = 0x000;
const PGCIT_ENTRIES_START: usize = 0x008;
const PGCI_SRP_SIZE: usize = 8;
const PGCI_SRP_PGC_START_BYTE: usize = 0x04;

// PGC offsets
const PGC_NR_OF_PROGRAMS: usize = 0x02;
const PGC_NR_OF_CELLS: usize = 0x03;
const PGC_PLAYBACK_TIME: usize = 0x04;
const PGC_PROGRAM_MAP_OFFSET: usize = 0xE6;
const PGC_CELL_PLAYBACK_OFFSET: usize = 0xE8;

// Cell playback entry (24 bytes each). Byte 0 holds, from the top bit:
// block_mode:2, block_type:2, seamless_play:1, interleaved:1,
// stc_discontinuity:1, seamless_angle:1 (libdvdread `cell_playback_t`).
const CELL_PLAYBACK_SIZE: usize = 24;
const CELL_PLAYBACK_TIME: usize = 0x04;
const CELL_FIRST_SECTOR: usize = 0x08;
const CELL_LAST_SECTOR: usize = 0x14;
const CELL_BLOCK_TYPE_ANGLE: u8 = 1;
const CELL_BLOCK_MODE_LAST: u8 = 3;

// NAV pack (the first pack of every VOBU). The DSI packet's data starts at
// byte 1031 (libdvdread `DSI_START_BYTE`); offsets below are into that data
// (libdvdread `nav_types.h`: dsi_gi 32 bytes, sml_pbi 148, sml_agli 54, then
// vobu_sri: next_video, fwda[19], next_vobu).
const NAV_DSI_START: usize = 0x407;
const DSI_NV_PCK_LBN: usize = 4;
const DSI_VOBU_EA: usize = 8;
const DSI_VOBU_VOB_IDN: usize = 24;
const DSI_VOBU_C_IDN: usize = 27;
const DSI_VOBU_SRI_NEXT_VOBU: usize = 32 + 148 + 54 + 4 + 19 * 4;
const SRI_END_OF_CELL: u32 = 0x3FFF_FFFF;

// VTS_PTT_SRPT offsets
const VTS_PTT_SRPT_NR_OF_TITLES: usize = 0x000;
const VTS_PTT_SRPT_OFFSETS_START: usize = 0x008;

// ============================================================================
// BINARY PARSING HELPERS
// ============================================================================

fn read_u16_be(data: &[u8], offset: usize) -> u16 {
    if offset + 2 > data.len() {
        return 0;
    }
    u16::from_be_bytes([data[offset], data[offset + 1]])
}

fn read_u32_be(data: &[u8], offset: usize) -> u32 {
    if offset + 4 > data.len() {
        return 0;
    }
    u32::from_be_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
}

/// Convert BCD byte to decimal (e.g., 0x59 → 59).
fn bcd_to_u8(bcd: u8) -> u8 {
    ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F)
}

/// Parse dvd_time_t (4 bytes BCD) to seconds.
fn dvd_time_to_seconds(data: &[u8], offset: usize) -> f64 {
    if offset + 4 > data.len() {
        return 0.0;
    }
    let hours = bcd_to_u8(data[offset]) as f64;
    let minutes = bcd_to_u8(data[offset + 1]) as f64;
    let seconds = bcd_to_u8(data[offset + 2]) as f64;

    let frame_byte = data[offset + 3];
    let frame_rate = match frame_byte >> 6 {
        0b01 => 25.0,
        0b11 => 29.97,
        _ => 25.0,
    };
    let frames = bcd_to_u8(frame_byte & 0x3F) as f64;

    hours * 3600.0 + minutes * 60.0 + seconds + frames / frame_rate
}

/// Extract frame rate from dvd_time_t byte 3.
fn dvd_time_frame_rate(data: &[u8], offset: usize) -> f64 {
    if offset + 4 > data.len() {
        return 29.97;
    }
    match data[offset + 3] >> 6 {
        0b01 => 25.0,
        0b11 => 29.97,
        _ => 29.97,
    }
}

// ============================================================================
// VIDEO/AUDIO ATTRIBUTE PARSING
// ============================================================================

struct VideoAttributes {
    width: u32,
    height: u32,
    frame_rate: f64,
    aspect_ratio: String,
}

fn parse_video_attr(data: &[u8], offset: usize) -> VideoAttributes {
    if offset + 2 > data.len() {
        return VideoAttributes {
            width: 720,
            height: 480,
            frame_rate: 29.97,
            aspect_ratio: "4:3".to_string(),
        };
    }

    let attr = read_u16_be(data, offset);

    // Video format: bits 13-12 (0=NTSC, 1=PAL)
    let video_format = (attr >> 12) & 0x03;
    let (default_height, default_fps) = match video_format {
        0 => (480u32, 29.97),
        1 => (576, 25.0),
        _ => (480, 29.97),
    };

    // Aspect ratio: bits 11-10 (0=4:3, 3=16:9)
    let aspect = (attr >> 10) & 0x03;
    let aspect_ratio = match aspect {
        0 => "4:3",
        3 => "16:9",
        _ => "4:3",
    };

    // Picture size: bits 3-2
    let pic_size = (attr >> 2) & 0x03;
    let width = match pic_size {
        0 => 720,
        1 => 704,
        2 => 352,
        3 => 352,
        _ => 720,
    };

    VideoAttributes {
        width,
        height: default_height,
        frame_rate: default_fps,
        aspect_ratio: aspect_ratio.to_string(),
    }
}

fn parse_audio_attr(data: &[u8], offset: usize, track_index: u32) -> DvdAudioTrack {
    if offset + AUDIO_ATTR_SIZE > data.len() {
        return DvdAudioTrack {
            index: track_index,
            language: "und".to_string(),
            format: "Unknown".to_string(),
            channels: 2,
            sample_rate: 48000,
        };
    }

    // Audio format: byte 0, bits 7-5
    let format_code = (data[offset] >> 5) & 0x07;
    let format = match format_code {
        0 => "AC3",
        2 => "MPEG-1",
        3 => "MPEG-2",
        4 => "LPCM",
        6 => "DTS",
        _ => "Unknown",
    };

    // Sample rate: byte 1, bits 5-4
    let sample_rate = match (data[offset + 1] >> 4) & 0x03 {
        0 => 48000u32,
        1 => 96000,
        _ => 48000,
    };

    // Language code: bytes 2-3 (two ASCII characters)
    let lang_hi = data[offset + 2];
    let lang_lo = data[offset + 3];
    let language = if lang_hi > 0 && lang_hi.is_ascii_alphabetic() {
        format!("{}{}", lang_hi as char, lang_lo as char)
    } else {
        "und".to_string()
    };

    // Channels: byte 7, bits 2-0 (stored as channels - 1)
    let channels = (data[offset + 7] & 0x07) as u32 + 1;

    DvdAudioTrack {
        index: track_index,
        language,
        format: format.to_string(),
        channels,
        sample_rate,
    }
}

// ============================================================================
// IFO PARSING (reads IFO files directly from filesystem)
// ============================================================================

/// Find the VIDEO_TS directory from a path.
/// Accepts: mount point, VIDEO_TS directory, or device path with VIDEO_TS child.
fn find_video_ts_dir(path: &str) -> Result<PathBuf> {
    let p = Path::new(path);

    // Check if path IS the VIDEO_TS directory
    if p.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case("VIDEO_TS")).unwrap_or(false) {
        if p.join("VIDEO_TS.IFO").exists() || p.join("video_ts.ifo").exists() {
            return Ok(p.to_path_buf());
        }
    }

    // Check if path contains VIDEO_TS
    let video_ts = p.join("VIDEO_TS");
    if video_ts.exists() {
        return Ok(video_ts);
    }

    // Try case-insensitive match
    let video_ts_lower = p.join("video_ts");
    if video_ts_lower.exists() {
        return Ok(video_ts_lower);
    }

    // A "flat" rip: the folder holds the VIDEO_TS *contents* without the
    // wrapping directory, and is named after the disc rather than VIDEO_TS
    // (what several rippers produce, and what you get by copying the files out
    // of a VIDEO_TS by hand). The IFO is the marker — the folder itself then
    // plays the role of the VIDEO_TS directory.
    if dir_has_dvd_ifo(p) {
        return Ok(p.to_path_buf());
    }

    bail!("VIDEO_TS directory not found at {:?}", path)
}

/// Whether a directory directly contains a DVD IFO (`VIDEO_TS.IFO` or a
/// `VTS_nn_0.IFO`), matched case-insensitively because rips vary and only
/// Windows/macOS filesystems are forgiving about it.
pub fn dir_has_dvd_ifo(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if name == "video_ts.ifo" {
            return true;
        }
        // VTS_01_0.IFO … VTS_99_0.IFO
        if let Some(rest) = name.strip_prefix("vts_") {
            if let Some(num) = rest.strip_suffix("_0.ifo") {
                if num.len() == 2 && num.chars().all(|c| c.is_ascii_digit()) {
                    return true;
                }
            }
        }
    }

    false
}

/// Find an IFO file, handling case sensitivity.
fn find_ifo_file(video_ts_dir: &Path, filename: &str) -> Result<PathBuf> {
    // Try exact case first
    let exact = video_ts_dir.join(filename);
    if exact.exists() {
        return Ok(exact);
    }

    // Try lowercase
    let lower = video_ts_dir.join(filename.to_lowercase());
    if lower.exists() {
        return Ok(lower);
    }

    // Try uppercase
    let upper = video_ts_dir.join(filename.to_uppercase());
    if upper.exists() {
        return Ok(upper);
    }

    bail!("IFO file not found: {} in {:?}", filename, video_ts_dir)
}

/// Enumerate all titles on a DVD by parsing IFO files.
pub fn enumerate_titles(device_path: &str) -> Result<DvdInfo> {
    let video_ts_dir = find_video_ts_dir(device_path)?;

    // Derive volume label from path.
    // On Windows, Path::file_name() returns None for root paths like "D:\",
    // so fall back to the drive letter (strip trailing `:\`).
    let volume_label = Path::new(device_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| {
            device_path
                .trim_end_matches(['\\', '/'])
                .trim_end_matches(':')
                .to_string()
        });

    // Read VIDEO_TS.IFO
    let vmg_ifo_path = find_ifo_file(&video_ts_dir, "VIDEO_TS.IFO")?;
    let vmg_data = std::fs::read(&vmg_ifo_path)
        .with_context(|| format!("Failed to read {:?}", vmg_ifo_path))?;

    // Validate identifier
    if vmg_data.len() < 0x100 || &vmg_data[0..12] != b"DVDVIDEO-VMG" {
        bail!("Invalid VIDEO_TS.IFO file");
    }

    let nr_of_title_sets = read_u16_be(&vmg_data, VMGI_NR_OF_TITLE_SETS) as usize;
    let title_entries = read_title_entries(&vmg_data)?;

    // Read each VTS IFO to get video/audio attributes and PGC info
    // Cache VTS data to avoid re-reading the same file multiple times
    let mut vts_cache: std::collections::HashMap<u8, Vec<u8>> = std::collections::HashMap::new();

    let mut titles = Vec::new();

    for (global_title_idx, entry) in title_entries.iter().enumerate() {
        let vts_nr = entry.title_set_nr;
        if vts_nr == 0 || vts_nr as usize > nr_of_title_sets {
            continue;
        }

        // Load VTS IFO if not cached
        if !vts_cache.contains_key(&vts_nr) {
            let vts_ifo_name = format!("VTS_{:02}_0.IFO", vts_nr);
            match find_ifo_file(&video_ts_dir, &vts_ifo_name) {
                Ok(vts_path) => match std::fs::read(&vts_path) {
                    Ok(data) => {
                        vts_cache.insert(vts_nr, data);
                    }
                    Err(e) => {
                        eprintln!("Warning: Failed to read {}: {}", vts_ifo_name, e);
                        continue;
                    }
                },
                Err(_) => continue,
            }
        }

        let vts_data = match vts_cache.get(&vts_nr) {
            Some(d) => d,
            None => continue,
        };

        // Parse video attributes
        let video = parse_video_attr(vts_data, VTSI_VTS_VIDEO_ATTR);

        // Parse audio attributes
        let nr_audio = if VTSI_NR_OF_VTS_AUDIO < vts_data.len() {
            vts_data[VTSI_NR_OF_VTS_AUDIO] as u32
        } else {
            0
        };

        let mut audio_tracks = Vec::new();
        for a in 0..nr_audio.min(8) {
            let audio_offset = VTSI_VTS_AUDIO_ATTR + (a as usize) * AUDIO_ATTR_SIZE;
            audio_tracks.push(parse_audio_attr(vts_data, audio_offset, a));
        }

        // Duration and chapters from the cells the extraction copies (angle
        // 1), so the picker shows what is extracted; the first PGC's own
        // playback time when the cells can't be mapped.
        let (pgc_duration, frame_rate) = parse_title_pgc_info(vts_data, entry.vts_ttn)
            .unwrap_or((0.0, video.frame_rate));
        let (duration, chapters) = match title_cells(vts_data, entry, None, 1) {
            Ok(cells) => {
                let chapters: Vec<DvdChapter> = (1..=entry.nr_of_ptts)
                    .map(|c| DvdChapter {
                        index: c as u32,
                        duration_seconds: cells
                            .iter()
                            .filter(|cell| cell.chapter == c)
                            .map(|cell| cell.seconds)
                            .sum(),
                    })
                    .collect();
                let total: f64 = chapters.iter().map(|c| c.duration_seconds).sum();
                (if total > 0.0 { total } else { pgc_duration }, chapters)
            }
            Err(_) => (
                pgc_duration,
                (1..=entry.nr_of_ptts)
                    .map(|c| DvdChapter { index: c as u32, duration_seconds: 0.0 })
                    .collect(),
            ),
        };

        // Use PGC frame rate if available, fall back to video attr
        let effective_frame_rate = if frame_rate > 0.0 {
            frame_rate
        } else {
            video.frame_rate
        };

        titles.push(DvdTitle {
            index: (global_title_idx + 1) as u32,
            duration_seconds: duration,
            chapters,
            audio_tracks,
            width: video.width,
            height: video.height,
            frame_rate: effective_frame_rate,
            aspect_ratio: video.aspect_ratio,
            angles: entry.nr_of_angles as u32,
            vts_number: vts_nr as u32,
        });
    }

    // Sort titles by duration (longest first) for convenience
    titles.sort_by(|a, b| b.duration_seconds.partial_cmp(&a.duration_seconds).unwrap_or(std::cmp::Ordering::Equal));

    Ok(DvdInfo {
        volume_label,
        device_path: device_path.to_string(),
        titles,
    })
}

/// One entry of the VMG's title table (TT_SRPT).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct TitleEntry {
    pub nr_of_angles: u8,
    pub nr_of_ptts: u16,
    pub title_set_nr: u8,
    pub vts_ttn: u8,
}

/// The VMG's title table, in disc order (title N is entry N - 1).
fn read_title_entries(vmg_data: &[u8]) -> Result<Vec<TitleEntry>> {
    let tt_srpt_sector = read_u32_be(vmg_data, VMGI_TT_SRPT_SECTOR) as usize;
    let tt_srpt_offset = tt_srpt_sector * DVD_BLOCK_LEN;
    if tt_srpt_offset >= vmg_data.len() {
        bail!("TT_SRPT sector offset out of bounds");
    }

    let nr_of_titles = read_u16_be(vmg_data, tt_srpt_offset + TT_SRPT_NR_OF_TITLES) as usize;
    let mut entries = Vec::new();
    for i in 0..nr_of_titles {
        let entry_offset = tt_srpt_offset + TT_SRPT_ENTRIES_START + i * TT_SRPT_ENTRY_SIZE;
        if entry_offset + TT_SRPT_ENTRY_SIZE > vmg_data.len() {
            break;
        }
        entries.push(TitleEntry {
            nr_of_angles: vmg_data[entry_offset + TITLE_NR_OF_ANGLES],
            nr_of_ptts: read_u16_be(vmg_data, entry_offset + TITLE_NR_OF_PTTS),
            title_set_nr: vmg_data[entry_offset + TITLE_SET_NR],
            vts_ttn: vmg_data[entry_offset + TITLE_VTS_TTN],
        });
    }
    Ok(entries)
}

/// Byte offset of PGC `pgcn` (1-based) in a VTS IFO.
fn pgc_offset(vts_data: &[u8], pgcn: usize) -> Result<usize> {
    let pgcit_offset = read_u32_be(vts_data, VTSI_VTS_PGCIT_SECTOR) as usize * DVD_BLOCK_LEN;
    if pgcit_offset == 0 || pgcit_offset >= vts_data.len() {
        bail!("PGCIT offset out of bounds");
    }
    let nr_of_pgci_srp = read_u16_be(vts_data, pgcit_offset + PGCIT_NR_OF_PGCI_SRP) as usize;
    if pgcn == 0 || pgcn > nr_of_pgci_srp {
        bail!("PGC number {} out of range (the title set has {})", pgcn, nr_of_pgci_srp);
    }
    let srp = pgcit_offset + PGCIT_ENTRIES_START + (pgcn - 1) * PGCI_SRP_SIZE;
    let pgc_abs = pgcit_offset + read_u32_be(vts_data, srp + PGCI_SRP_PGC_START_BYTE) as usize;
    if pgc_abs + 0xEC > vts_data.len() {
        bail!("PGC {} data out of bounds", pgcn);
    }
    Ok(pgc_abs)
}

/// Absolute offset of a title's PTT (chapter) entries in a VTS IFO.
fn ptt_entries_offset(vts_data: &[u8], vts_ttn: u8) -> Result<usize> {
    let ptt_srpt_offset = read_u32_be(vts_data, VTSI_VTS_PTT_SRPT_SECTOR) as usize * DVD_BLOCK_LEN;
    if ptt_srpt_offset == 0 || ptt_srpt_offset >= vts_data.len() {
        bail!("PTT_SRPT offset out of bounds");
    }
    let nr_of_ptt_titles = read_u16_be(vts_data, ptt_srpt_offset + VTS_PTT_SRPT_NR_OF_TITLES) as usize;
    let index = (vts_ttn as usize).saturating_sub(1);
    if vts_ttn == 0 || index >= nr_of_ptt_titles {
        bail!("VTS title number {} out of range (max {})", vts_ttn, nr_of_ptt_titles);
    }
    let rel = read_u32_be(vts_data, ptt_srpt_offset + VTS_PTT_SRPT_OFFSETS_START + index * 4) as usize;
    let abs = ptt_srpt_offset + rel;
    if abs >= vts_data.len() {
        bail!("PTT entries offset out of bounds");
    }
    Ok(abs)
}

/// The first PGC's playback time and frame rate for a title (what the picker
/// falls back to when the title's cells can't be mapped).
fn parse_title_pgc_info(vts_data: &[u8], vts_ttn: u8) -> Result<(f64, f64)> {
    let ptt = ptt_entries_offset(vts_data, vts_ttn)?;
    let pgc_abs = pgc_offset(vts_data, read_u16_be(vts_data, ptt) as usize)?;
    Ok((
        dvd_time_to_seconds(vts_data, pgc_abs + PGC_PLAYBACK_TIME),
        dvd_time_frame_rate(vts_data, pgc_abs + PGC_PLAYBACK_TIME),
    ))
}

/// One cell a title plays, as the extraction copies it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct CellRef {
    /// Chapter (PTT, 1-based) the cell belongs to.
    pub chapter: u16,
    pub pgcn: u16,
    /// Cell number in its PGC (1-based).
    pub cell: u8,
    /// Sectors relative to the start of the title set's title VOBs: the
    /// offsets `DVDReadBlocks` takes on a `DVD_READ_TITLE_VOBS` handle.
    pub first_sector: u32,
    pub last_sector: u32,
    /// Part of an interleaved block (seamless angles or branching): the
    /// sector range then spans the other angles' units too, and the copy has
    /// to follow the NAV packs.
    pub interleaved: bool,
    /// Cells in the angle block this cell came from (1 outside one).
    pub angles_in_block: u8,
    pub seconds: f64,
}

/// The cells a title plays, chapter by chapter, for one angle: THE decision
/// of what a DVD import copies (and what the picker's durations count).
///
/// `chapters` is an inclusive 1-based range (`None` = every chapter);
/// `angle` is 1-based. Each chapter's (PGC, program) comes from the VTS
/// PTT table and the program's cells from the PGC's program map, so a title
/// of one PGC and a title of one PGC per chapter both work. In an angle block
/// only the chosen angle's cell is taken.
pub(crate) fn title_cells(
    vts_data: &[u8],
    title: &TitleEntry,
    chapters: Option<(u16, u16)>,
    angle: u8,
) -> Result<Vec<CellRef>> {
    let nr_ptts = title.nr_of_ptts;
    let (first_ch, last_ch) = chapters.unwrap_or((1, nr_ptts));
    if nr_ptts == 0 {
        bail!("the title has no chapters in the disc's title table");
    }
    if first_ch == 0 || first_ch > last_ch || last_ch > nr_ptts {
        bail!(
            "the title has {} chapter{}; asked for {}-{}",
            nr_ptts,
            if nr_ptts == 1 { "" } else { "s" },
            first_ch,
            last_ch
        );
    }
    let nr_angles = title.nr_of_angles.max(1);
    if angle == 0 || angle > nr_angles {
        bail!("the title has {} angle(s); asked for angle {}", nr_angles, angle);
    }

    let ptt = ptt_entries_offset(vts_data, title.vts_ttn)?;
    if ptt + nr_ptts as usize * 4 > vts_data.len() {
        bail!("the title's PTT table runs past the end of the IFO");
    }
    // Every chapter's (PGC, program). A chapter plays from its program up to
    // the next program some chapter starts at (or the PGC's end): programs no
    // chapter points at still play, as on a player.
    let starts: Vec<(u16, usize)> = (0..nr_ptts as usize)
        .map(|i| (read_u16_be(vts_data, ptt + i * 4), read_u16_be(vts_data, ptt + i * 4 + 2) as usize))
        .collect();
    let mut cells = Vec::new();

    for chapter in first_ch..=last_ch {
        let (pgcn, pgn) = starts[chapter as usize - 1];

        let pgc = pgc_offset(vts_data, pgcn as usize)
            .with_context(|| format!("Chapter {}", chapter))?;
        let nr_programs = vts_data[pgc + PGC_NR_OF_PROGRAMS] as usize;
        let nr_cells = vts_data[pgc + PGC_NR_OF_CELLS] as usize;
        let map = pgc + read_u16_be(vts_data, pgc + PGC_PROGRAM_MAP_OFFSET) as usize;
        let table = pgc + read_u16_be(vts_data, pgc + PGC_CELL_PLAYBACK_OFFSET) as usize;
        if map == pgc || table == pgc {
            bail!("PGC {} has no program map or cell table", pgcn);
        }
        if pgn == 0 || pgn > nr_programs {
            bail!("Chapter {} names program {} of PGC {}, which has {}", chapter, pgn, pgcn, nr_programs);
        }
        if map + nr_programs > vts_data.len() || table + nr_cells * CELL_PLAYBACK_SIZE > vts_data.len() {
            bail!("PGC {} tables out of bounds", pgcn);
        }
        let mut last_pgn = pgn;
        while last_pgn < nr_programs && !starts.contains(&(pgcn, last_pgn + 1)) {
            last_pgn += 1;
        }
        let start = vts_data[map + pgn - 1] as usize;
        let end = if last_pgn < nr_programs { (vts_data[map + last_pgn] as usize).saturating_sub(1) } else { nr_cells };
        if start == 0 || start > end || end > nr_cells {
            bail!("Program {} of PGC {} has an invalid cell range {}-{}", pgn, pgcn, start, end);
        }

        let cell_at = |c: usize| &vts_data[table + (c - 1) * CELL_PLAYBACK_SIZE..table + c * CELL_PLAYBACK_SIZE];
        let mut c = start;
        while c <= end {
            let flags = cell_at(c)[0];
            let (chosen, angles_in_block, next) = if (flags >> 4) & 0x03 == CELL_BLOCK_TYPE_ANGLE {
                // An angle block: cells for angle 1, 2, … up to the one marked last.
                let mut last = c;
                while (cell_at(last)[0] >> 6) & 0x03 != CELL_BLOCK_MODE_LAST {
                    last += 1;
                    if last > nr_cells {
                        bail!("Angle block from cell {} of PGC {} has no last cell", c, pgcn);
                    }
                }
                let n = last - c + 1;
                if angle as usize > n {
                    bail!("Angle block at cell {} of PGC {} has {} angles; asked for angle {}", c, pgcn, n, angle);
                }
                (c + angle as usize - 1, n as u8, last + 1)
            } else {
                (c, 1, c + 1)
            };
            let raw = cell_at(chosen);
            let first_sector = read_u32_be(raw, CELL_FIRST_SECTOR);
            let last_sector = read_u32_be(raw, CELL_LAST_SECTOR);
            if last_sector < first_sector {
                bail!("Cell {} of PGC {} ends (sector {}) before it starts ({})", chosen, pgcn, last_sector, first_sector);
            }
            cells.push(CellRef {
                chapter,
                pgcn,
                cell: chosen as u8,
                first_sector,
                last_sector,
                interleaved: raw[0] & 0x04 != 0,
                angles_in_block,
                seconds: dvd_time_to_seconds(raw, CELL_PLAYBACK_TIME),
            });
            c = next;
        }
    }

    if cells.is_empty() {
        bail!("the title has no cells to copy");
    }
    Ok(cells)
}

/// A run of sectors to copy.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Segment {
    /// Copy `first..=last` as it is.
    Range { first: u32, last: u32 },
    /// An interleaved cell: walk its NAV packs (`walk_interleaved`).
    Interleaved { first: u32, last: u32, angles: u8 },
}

/// The cells as reads: contiguous cells become ranges, merged where one
/// starts right after the last (never where they overlap: a cell played
/// twice is copied twice, as a player shows it twice).
pub(crate) fn copy_plan(cells: &[CellRef]) -> Vec<Segment> {
    let mut plan: Vec<Segment> = Vec::new();
    for cell in cells {
        if cell.interleaved {
            plan.push(Segment::Interleaved {
                first: cell.first_sector,
                last: cell.last_sector,
                angles: cell.angles_in_block.max(1),
            });
            continue;
        }
        if let Some(Segment::Range { last, .. }) = plan.last_mut() {
            if cell.first_sector as u64 == *last as u64 + 1 {
                *last = cell.last_sector;
                continue;
            }
        }
        plan.push(Segment::Range { first: cell.first_sector, last: cell.last_sector });
    }
    plan
}

/// Blocks the plan will write: exact for ranges, the cell's share for an
/// interleaved one (its span divided among the angles). Progress only.
pub(crate) fn estimated_blocks(plan: &[Segment]) -> u64 {
    plan.iter()
        .map(|s| match *s {
            Segment::Range { first, last } => (last - first) as u64 + 1,
            Segment::Interleaved { first, last, angles } => ((last - first) as u64 + 1) / angles.max(1) as u64,
        })
        .sum()
}

/// What the extraction reads from a NAV pack's DSI.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Dsi {
    pub nv_pck_lbn: u32,
    pub vobu_ea: u32,
    pub vobu_vob_idn: u16,
    pub vobu_c_idn: u8,
    pub next_vobu: u32,
}

/// Parse a NAV pack's DSI, or fail if the block isn't a NAV pack.
pub(crate) fn parse_nav_dsi(block: &[u8]) -> Result<Dsi> {
    if block.len() < DVD_BLOCK_LEN
        || block[0..4] != [0, 0, 1, 0xBA]
        || block[0x400..0x404] != [0, 0, 1, 0xBF]
        || block[0x406] != 0x01
    {
        bail!("not a NAV pack");
    }
    let dsi = &block[NAV_DSI_START..];
    Ok(Dsi {
        nv_pck_lbn: read_u32_be(dsi, DSI_NV_PCK_LBN),
        vobu_ea: read_u32_be(dsi, DSI_VOBU_EA),
        vobu_vob_idn: read_u16_be(dsi, DSI_VOBU_VOB_IDN),
        vobu_c_idn: dsi[DSI_VOBU_C_IDN],
        next_vobu: read_u32_be(dsi, DSI_VOBU_SRI_NEXT_VOBU),
    })
}

/// The sector ranges of an interleaved cell that belong to it: VOBU by VOBU
/// from its first NAV pack, each VOBU being the NAV pack and the `vobu_ea`
/// sectors after it, the next found by the DSI's `next_vobu`, which skips the
/// other angles' interleaved units (libdvdread's `play_title.c`).
pub(crate) fn walk_interleaved(
    first: u32,
    last: u32,
    mut read_block: impl FnMut(u32) -> Result<Vec<u8>>,
) -> Result<Vec<(u32, u32)>> {
    let mut ranges: Vec<(u32, u32)> = Vec::new();
    let mut cur = first;
    while cur <= last {
        let block = read_block(cur)?;
        let dsi = parse_nav_dsi(&block).with_context(|| format!("Interleaved cell: sector {}", cur))?;
        if dsi.nv_pck_lbn != cur {
            bail!("Interleaved cell: the NAV pack at sector {} says it is at {}", cur, dsi.nv_pck_lbn);
        }
        if dsi.vobu_ea >= 1024 {
            bail!("Interleaved cell: implausible VOBU length {} at sector {}", dsi.vobu_ea, cur);
        }
        let end = (cur + dsi.vobu_ea).min(last);
        match ranges.last_mut() {
            Some((_, prev_end)) if *prev_end + 1 == cur => *prev_end = end,
            _ => ranges.push((cur, end)),
        }
        let step = dsi.next_vobu & 0x7FFF_FFFF;
        if dsi.next_vobu == SRI_END_OF_CELL || step == SRI_END_OF_CELL {
            break;
        }
        if step == 0 {
            bail!("Interleaved cell: the NAV pack at sector {} does not advance", cur);
        }
        cur += step;
    }
    Ok(ranges)
}

/// A source of DVD sectors (libdvdread's title VOBs, or a test's bytes).
pub(crate) trait BlockSource {
    /// Read up to `count` sectors from `offset` into `buf`; returns how many
    /// were read (0 or less = a read error).
    fn read(&mut self, offset: u32, count: usize, buf: &mut [u8]) -> isize;
}

/// What a copy wrote.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct CopyStats {
    pub blocks: u64,
    /// The sector a read failed at, after something had been written.
    pub stopped_at: Option<u32>,
}

/// Copy a plan's sectors from `src` to `out`, in order. A read that fails
/// after something was written stops the copy (reported in `stopped_at`,
/// as before: some discs have unreadable sectors at the end); one that fails
/// before anything was written is an error.
pub(crate) fn copy_title(
    src: &mut dyn BlockSource,
    plan: &[Segment],
    out: &mut dyn std::io::Write,
    mut progress: impl FnMut(u64, u64),
) -> Result<CopyStats> {
    const BATCH: usize = 128;
    let total = estimated_blocks(plan).max(1);
    let mut buffer = vec![0u8; BATCH * DVD_BLOCK_LEN];
    let mut stats = CopyStats::default();

    for segment in plan {
        let ranges = match *segment {
            Segment::Range { first, last } => vec![(first, last)],
            Segment::Interleaved { first, last, .. } => walk_interleaved(first, last, |sector| {
                let mut block = vec![0u8; DVD_BLOCK_LEN];
                if src.read(sector, 1, &mut block) != 1 {
                    bail!("Failed to read DVD sector {}", sector);
                }
                Ok(block)
            })?,
        };
        for (first, last) in ranges {
            let mut offset = first as u64;
            while offset <= last as u64 {
                let to_read = ((last as u64 - offset + 1) as usize).min(BATCH);
                let read = src.read(offset as u32, to_read, &mut buffer);
                if read <= 0 {
                    if stats.blocks > 0 {
                        stats.stopped_at = Some(offset as u32);
                        return Ok(stats);
                    }
                    bail!("Failed to read DVD blocks at offset {}", offset);
                }
                let read = (read as usize).min(to_read);
                out.write_all(&buffer[..read * DVD_BLOCK_LEN])
                    .context("Failed to write to output file")?;
                stats.blocks += read as u64;
                offset += read as u64;
                progress(stats.blocks, total.max(stats.blocks));
            }
        }
    }
    Ok(stats)
}

/// A title's entry in the VMG title table and its title set's IFO, read
/// from the disc's filesystem (IFOs are never CSS-encrypted).
fn load_title(device_path: &str, title_index: u32) -> Result<(TitleEntry, Vec<u8>)> {
    let video_ts_dir = find_video_ts_dir(device_path)?;
    let vmg_path = find_ifo_file(&video_ts_dir, "VIDEO_TS.IFO")?;
    let vmg_data = std::fs::read(&vmg_path).with_context(|| format!("Failed to read {:?}", vmg_path))?;
    if vmg_data.len() < 0x100 || &vmg_data[0..12] != b"DVDVIDEO-VMG" {
        bail!("Invalid VIDEO_TS.IFO file");
    }
    let entries = read_title_entries(&vmg_data)?;
    let entry = *title_index
        .checked_sub(1)
        .and_then(|i| entries.get(i as usize))
        .with_context(|| format!("Title {} not found (the disc has {})", title_index, entries.len()))?;
    let vts_name = format!("VTS_{:02}_0.IFO", entry.title_set_nr);
    let vts_path = find_ifo_file(&video_ts_dir, &vts_name)?;
    let vts_data = std::fs::read(&vts_path).with_context(|| format!("Failed to read {:?}", vts_path))?;
    Ok((entry, vts_data))
}

// ============================================================================
// LIBDVDREAD FFI FOR EXTRACTION
// ============================================================================

const DVD_READ_TITLE_VOBS: i32 = 3;

type FnDvdOpen = unsafe extern "C" fn(*const c_char) -> *mut std::ffi::c_void;
type FnDvdClose = unsafe extern "C" fn(*mut std::ffi::c_void);
type FnDvdOpenFile = unsafe extern "C" fn(*mut std::ffi::c_void, i32, i32) -> *mut std::ffi::c_void;
type FnDvdCloseFile = unsafe extern "C" fn(*mut std::ffi::c_void);
type FnDvdFileSize = unsafe extern "C" fn(*mut std::ffi::c_void) -> isize;
type FnDvdReadBlocks =
    unsafe extern "C" fn(*mut std::ffi::c_void, i32, usize, *mut u8) -> isize;

/// Dynamically loaded libdvdread library.
struct DvdReadLib {
    _lib: libloading::Library,
    dvd_open: FnDvdOpen,
    dvd_close: FnDvdClose,
    dvd_open_file: FnDvdOpenFile,
    dvd_close_file: FnDvdCloseFile,
    dvd_file_size: FnDvdFileSize,
    dvd_read_blocks: FnDvdReadBlocks,
}

impl DvdReadLib {
    /// Load libdvdread from the given path.
    fn load(lib_path: &Path) -> Result<Self> {
        unsafe {
            let lib = libloading::Library::new(lib_path)
                .with_context(|| format!("Failed to load libdvdread from {:?}", lib_path))?;

            let dvd_open: FnDvdOpen = *lib.get(b"DVDOpen\0")
                .context("Failed to find DVDOpen in libdvdread")?;
            let dvd_close: FnDvdClose = *lib.get(b"DVDClose\0")
                .context("Failed to find DVDClose in libdvdread")?;
            let dvd_open_file: FnDvdOpenFile = *lib.get(b"DVDOpenFile\0")
                .context("Failed to find DVDOpenFile in libdvdread")?;
            let dvd_close_file: FnDvdCloseFile = *lib.get(b"DVDCloseFile\0")
                .context("Failed to find DVDCloseFile in libdvdread")?;
            let dvd_file_size: FnDvdFileSize = *lib.get(b"DVDFileSize\0")
                .context("Failed to find DVDFileSize in libdvdread")?;
            let dvd_read_blocks: FnDvdReadBlocks = *lib.get(b"DVDReadBlocks\0")
                .context("Failed to find DVDReadBlocks in libdvdread")?;

            Ok(Self {
                _lib: lib,
                dvd_open,
                dvd_close,
                dvd_open_file,
                dvd_close_file,
                dvd_file_size,
                dvd_read_blocks,
            })
        }
    }

    /// Try to load libdvdread from known locations.
    fn load_auto() -> Result<Self> {
        // Try bundled location first via DependencyLocator
        if let Ok(deps) = crate::dependency_locator::DependencyLocator::new() {
            let lib_path = deps.dvdread_library_path();
            if lib_path.exists() {
                return Self::load(&lib_path);
            }
        }

        // Try system library paths
        #[cfg(target_os = "macos")]
        {
            // Homebrew paths
            let paths = [
                "/opt/homebrew/lib/libdvdread.dylib",
                "/usr/local/lib/libdvdread.dylib",
            ];
            for path in &paths {
                let p = Path::new(path);
                if p.exists() {
                    return Self::load(p);
                }
            }
            // Try generic name (searches DYLD_LIBRARY_PATH)
            if let Ok(lib) = Self::load(Path::new("libdvdread.dylib")) {
                return Ok(lib);
            }
        }

        #[cfg(target_os = "windows")]
        {
            if let Ok(lib) = Self::load(Path::new("dvdread.dll")) {
                return Ok(lib);
            }
            if let Ok(lib) = Self::load(Path::new("libdvdread.dll")) {
                return Ok(lib);
            }
        }

        #[cfg(target_os = "linux")]
        {
            let paths = [
                "/usr/lib/x86_64-linux-gnu/libdvdread.so",  // Debian/Ubuntu
                "/usr/lib64/libdvdread.so",                  // Fedora/RHEL
                "/usr/lib/libdvdread.so",                    // Arch
                "/usr/local/lib/libdvdread.so",
            ];
            for path in &paths {
                let p = Path::new(path);
                if p.exists() {
                    if let Ok(lib) = Self::load(p) {
                        return Ok(lib);
                    }
                }
            }
            // Try generic name (searches LD_LIBRARY_PATH)
            if let Ok(lib) = Self::load(Path::new("libdvdread.so")) {
                return Ok(lib);
            }
        }

        bail!(
            "libdvdread not found. DVD extraction requires libdvdread.\n\
             macOS: brew install libdvdread\n\
             Linux: sudo apt install libdvdread-dev (Debian/Ubuntu) or sudo dnf install libdvdread-devel (Fedora)\n\
             Windows: place dvdread.dll in the application directory"
        )
    }
}

/// libdvdread's title VOBs as a `BlockSource`.
struct LibDvdReadSource<'a> {
    file: *mut std::ffi::c_void,
    read_blocks: FnDvdReadBlocks,
    _lib: std::marker::PhantomData<&'a DvdReadLib>,
}

impl BlockSource for LibDvdReadSource<'_> {
    fn read(&mut self, offset: u32, count: usize, buf: &mut [u8]) -> isize {
        let count = count.min(buf.len() / DVD_BLOCK_LEN);
        if offset > i32::MAX as u32 {
            return -1;
        }
        unsafe { (self.read_blocks)(self.file, offset as i32, count, buf.as_mut_ptr()) }
    }
}

/// Extract a DVD title to an MPEG-PS file using libdvdread.
///
/// Copies exactly the cells the title plays (`title_cells`): only this title
/// of its title set, one angle, and the chapter range if one is given
/// (inclusive, 1-based). Reads go through libdvdread, which handles CSS
/// decryption if libdvdcss is installed.
pub fn extract_title(
    device_path: &str,
    title_index: u32,
    chapters: Option<(u16, u16)>,
    angle: u8,
    output_path: &Path,
    reporter: &ProgressReporter,
) -> Result<()> {
    // Decide what to copy before touching the disc, so a bad chapter range or
    // angle is refused without needing libdvdread at all.
    let (entry, vts_data) = load_title(device_path, title_index)?;
    let cells = title_cells(&vts_data, &entry, chapters, angle)
        .with_context(|| format!("Title {}", title_index))?;
    let plan = copy_plan(&cells);
    let estimate = estimated_blocks(&plan);
    let vts_nr = entry.title_set_nr;

    let (first_ch, last_ch) = chapters.unwrap_or((1, entry.nr_of_ptts));
    reporter.send_log(
        crate::models::LogLevel::Info,
        &format!(
            "Extracting title {} (title {} of VTS {}): chapters {}-{}, angle {} of {}, {} cell(s), ~{} blocks ({:.1} MB)",
            title_index,
            entry.vts_ttn,
            vts_nr,
            first_ch,
            last_ch,
            angle,
            entry.nr_of_angles.max(1),
            cells.len(),
            estimate,
            (estimate as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0)
        ),
    );

    let lib = DvdReadLib::load_auto()?;

    // Open DVD
    let c_path = CString::new(device_path)
        .context("Invalid device path")?;

    let dvd = unsafe { (lib.dvd_open)(c_path.as_ptr()) };
    if dvd.is_null() {
        bail!(
            "Failed to open DVD at {}. If the disc is encrypted, \
             install libdvdcss:\n  macOS: brew install libdvdcss\n  \
             Windows: place libdvdcss-2.dll in the app directory",
            device_path
        );
    }

    // Ensure DVD is closed on any exit path
    struct DvdGuard {
        dvd: *mut std::ffi::c_void,
        close_fn: FnDvdClose,
    }
    impl Drop for DvdGuard {
        fn drop(&mut self) {
            unsafe { (self.close_fn)(self.dvd) }
        }
    }
    let _dvd_guard = DvdGuard {
        dvd,
        close_fn: lib.dvd_close,
    };

    // Open title VOBs
    let dvd_file = unsafe { (lib.dvd_open_file)(dvd, vts_nr as i32, DVD_READ_TITLE_VOBS) };
    if dvd_file.is_null() {
        bail!("Failed to open title VOBs for VTS {}", vts_nr);
    }

    struct FileGuard {
        file: *mut std::ffi::c_void,
        close_fn: FnDvdCloseFile,
    }
    impl Drop for FileGuard {
        fn drop(&mut self) {
            unsafe { (self.close_fn)(self.file) }
        }
    }
    let _file_guard = FileGuard {
        file: dvd_file,
        close_fn: lib.dvd_close_file,
    };

    // The cells must lie inside the title VOBs.
    let total_blocks = unsafe { (lib.dvd_file_size)(dvd_file) };
    if total_blocks <= 0 {
        bail!("DVD file size is 0 for VTS {}", vts_nr);
    }
    if let Some(cell) = cells.iter().find(|c| c.last_sector as i64 >= total_blocks as i64) {
        bail!(
            "Title {}: cell {} of PGC {} ends at sector {}, past the title set's {} sectors",
            title_index, cell.cell, cell.pgcn, cell.last_sector, total_blocks
        );
    }

    let mut output_file = std::io::BufWriter::new(
        std::fs::File::create(output_path)
            .with_context(|| format!("Failed to create output file {:?}", output_path))?,
    );

    let mut source = LibDvdReadSource {
        file: dvd_file,
        read_blocks: lib.dvd_read_blocks,
        _lib: std::marker::PhantomData,
    };
    let start_time = std::time::Instant::now();
    let mut last_decile = 0;
    let stats = copy_title(&mut source, &plan, &mut output_file, |done, total| {
        let elapsed = start_time.elapsed().as_secs_f64();
        let rate = if elapsed > 0.0 { done as f64 / elapsed } else { 0.0 };
        let eta = if rate > 0.0 { (total - done) as f64 / rate } else { 0.0 };
        let progress_info =
            crate::models::ProgressInfo::new(done as i32, total as i32, rate, eta);
        reporter.send_progress_phase(&progress_info, "extracting");

        let decile = done * 10 / total.max(1);
        if decile > last_decile {
            last_decile = decile;
            reporter.send_log(
                crate::models::LogLevel::Debug,
                &format!(
                    "Extracted {:.1} MB ({}%)",
                    (done as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0),
                    decile * 10
                ),
            );
        }
    })?;

    if let Some(sector) = stats.stopped_at {
        // Partial read is OK — some DVDs have unreadable sectors at the end
        reporter.send_log(
            crate::models::LogLevel::Warning,
            &format!(
                "Read stopped at sector {} after {} blocks (partial extraction)",
                sector, stats.blocks
            ),
        );
    }

    output_file
        .flush()
        .context("Failed to flush output file")?;

    let total_mb = (stats.blocks as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0);
    reporter.send_log(
        crate::models::LogLevel::Info,
        &format!(
            "Extraction complete: {:.1} MB written to {:?}",
            total_mb, output_path
        ),
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Creates the named empty files in a fresh temp dir and returns it.
    fn dir_with(files: &[&str]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for rel in files {
            let path = dir.path().join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"").unwrap();
        }
        dir
    }

    #[test]
    fn test_find_video_ts_dir_nested() {
        let dir = dir_with(&["VIDEO_TS/VIDEO_TS.IFO", "VIDEO_TS/VTS_01_1.VOB"]);
        let found = find_video_ts_dir(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(found, dir.path().join("VIDEO_TS"));
    }

    #[test]
    fn test_find_video_ts_dir_is_video_ts() {
        let dir = dir_with(&["VIDEO_TS/VIDEO_TS.IFO"]);
        let video_ts = dir.path().join("VIDEO_TS");
        let found = find_video_ts_dir(video_ts.to_str().unwrap()).unwrap();
        assert_eq!(found, video_ts);
    }

    /// A flat rip — the VIDEO_TS contents in a folder named after the disc.
    /// The folder itself stands in for the VIDEO_TS directory; without this the
    /// worker bails and the folder cannot be opened as a DVD at all.
    #[test]
    fn test_find_video_ts_dir_flat_rip() {
        let dir = dir_with(&["VIDEO_TS.IFO", "VTS_01_0.IFO", "VTS_01_1.VOB"]);
        let found = find_video_ts_dir(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(found, dir.path());
    }

    #[test]
    fn test_find_video_ts_dir_flat_rip_vts_ifo_only() {
        let dir = dir_with(&["vts_01_0.ifo", "vts_01_1.vob"]);
        let found = find_video_ts_dir(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(found, dir.path());
    }

    #[test]
    fn test_find_video_ts_dir_rejects_plain_folder() {
        let dir = dir_with(&["a.mp4", "b.mkv"]);
        assert!(find_video_ts_dir(dir.path().to_str().unwrap()).is_err());
    }

    #[test]
    fn test_dir_has_dvd_ifo() {
        assert!(dir_has_dvd_ifo(dir_with(&["VIDEO_TS.IFO"]).path()));
        assert!(dir_has_dvd_ifo(dir_with(&["video_ts.ifo"]).path()));
        assert!(dir_has_dvd_ifo(dir_with(&["VTS_01_0.IFO"]).path()));
        assert!(dir_has_dvd_ifo(dir_with(&["VTS_99_0.IFO"]).path()));

        // Not IFOs that name a title set root.
        assert!(!dir_has_dvd_ifo(dir_with(&["VTS_1_0.IFO"]).path()));
        assert!(!dir_has_dvd_ifo(dir_with(&["VTS_01_1.VOB"]).path()));
        assert!(!dir_has_dvd_ifo(dir_with(&["notes.ifo"]).path()));
        assert!(!dir_has_dvd_ifo(dir_with(&[]).path()));
        assert!(!dir_has_dvd_ifo(std::path::Path::new("/nonexistent/xyz")));
    }

    #[test]
    fn test_bcd_to_u8() {
        assert_eq!(bcd_to_u8(0x00), 0);
        assert_eq!(bcd_to_u8(0x59), 59);
        assert_eq!(bcd_to_u8(0x23), 23);
        assert_eq!(bcd_to_u8(0x01), 1);
    }

    #[test]
    fn test_dvd_time_to_seconds() {
        // 1 hour, 30 minutes, 0 seconds, 0 frames @ 25fps
        let data = [0x01, 0x30, 0x00, 0b01_000000]; // 01=25fps
        assert!((dvd_time_to_seconds(&data, 0) - 5400.0).abs() < 0.1);

        // 0 hours, 5 minutes, 30 seconds, 15 frames @ 29.97fps
        let data = [0x00, 0x05, 0x30, 0b11_010101]; // 11=29.97fps, 0x15=15 BCD
        let expected = 5.0 * 60.0 + 30.0 + 15.0 / 29.97;
        assert!((dvd_time_to_seconds(&data, 0) - expected).abs() < 0.1);
    }

    #[test]
    fn test_parse_video_attr() {
        // NTSC 16:9 720x480
        // Bits: 01(MPEG-2) 00(NTSC) 11(16:9) 00(perm) 0 0 0 0 00(720x) 0 0
        let data = [0b01_00_11_00, 0b0000_00_0_0];
        let attr = parse_video_attr(&data, 0);
        assert_eq!(attr.width, 720);
        assert_eq!(attr.height, 480);
        assert_eq!(attr.aspect_ratio, "16:9");

        // PAL 4:3 720x576
        // Bits: 01(MPEG-2) 01(PAL) 00(4:3) 00 0 0 0 0 00(720x) 0 0
        let data = [0b01_01_00_00, 0b0000_00_0_0];
        let attr = parse_video_attr(&data, 0);
        assert_eq!(attr.width, 720);
        assert_eq!(attr.height, 576);
        assert_eq!(attr.aspect_ratio, "4:3");
    }

    #[test]
    fn test_parse_audio_attr() {
        // AC3, 48kHz, English (0x65 0x6E = 'en'), 5.1 channels
        let data = [
            0b000_0_00_00, // AC3, no MCE, no lang type, no app mode
            0b00_00_0000, // 16bit, 48kHz
            0x65,         // 'e'
            0x6E,         // 'n'
            0x00,         // lang extension
            0x01,         // code extension (normal)
            0x00,         // unknown
            0x05,         // channels - 1 = 5 (6 channels = 5.1)
        ];
        let track = parse_audio_attr(&data, 0, 0);
        assert_eq!(track.format, "AC3");
        assert_eq!(track.language, "en");
        assert_eq!(track.channels, 6);
        assert_eq!(track.sample_rate, 48000);
    }

    // ========================================================================
    // Helper: write a big-endian u16 into a byte buffer
    // ========================================================================
    fn put_u16(data: &mut [u8], offset: usize, val: u16) {
        data[offset..offset + 2].copy_from_slice(&val.to_be_bytes());
    }

    fn put_u32(data: &mut [u8], offset: usize, val: u32) {
        data[offset..offset + 4].copy_from_slice(&val.to_be_bytes());
    }

    // ========================================================================
    // Build a synthetic VIDEO_TS.IFO (VMGI)
    //
    // Layout (2 sectors = 4096 bytes):
    //   Sector 0: VMGI_MAT — identifier, nr_of_title_sets, tt_srpt pointer
    //   Sector 1: TT_SRPT  — 2 title entries
    // ========================================================================
    fn build_test_vmg_ifo() -> Vec<u8> {
        let mut d = vec![0u8; 4096];

        // --- VMGI_MAT (sector 0) ---
        d[0..12].copy_from_slice(b"DVDVIDEO-VMG");
        put_u16(&mut d, VMGI_NR_OF_TITLE_SETS, 1); // 1 VTS on disc
        put_u32(&mut d, VMGI_TT_SRPT_SECTOR, 1);   // TT_SRPT in sector 1

        // --- TT_SRPT (sector 1, byte 2048) ---
        let tt = 1 * DVD_BLOCK_LEN;
        put_u16(&mut d, tt + TT_SRPT_NR_OF_TITLES, 2); // 2 titles

        // Title 1: 5 chapters, VTS 1, VTS-TTN 1, 1 angle
        let t1 = tt + TT_SRPT_ENTRIES_START;
        d[t1 + TITLE_NR_OF_ANGLES] = 1;
        put_u16(&mut d, t1 + TITLE_NR_OF_PTTS, 5);
        d[t1 + TITLE_SET_NR] = 1;
        d[t1 + TITLE_VTS_TTN] = 1;

        // Title 2: 2 chapters, VTS 1, VTS-TTN 2, 1 angle
        let t2 = t1 + TT_SRPT_ENTRY_SIZE;
        d[t2 + TITLE_NR_OF_ANGLES] = 1;
        put_u16(&mut d, t2 + TITLE_NR_OF_PTTS, 2);
        d[t2 + TITLE_SET_NR] = 1;
        d[t2 + TITLE_VTS_TTN] = 2;

        d
    }

    // ========================================================================
    // Build a synthetic VTS_01_0.IFO (VTSI)
    //
    // Layout (4 sectors = 8192 bytes):
    //   Sector 0: VTSI_MAT — video/audio attrs, table sector pointers
    //   Sector 1: VTS_PTT_SRPT — chapter-to-PGC mapping for 2 titles
    //   Sector 2: VTS_PGCIT — 2 PGCs with program_map + cell_playback
    //   Sector 3: (overflow for PGC 2 data)
    //
    // Title 1 (VTS-TTN 1): 5 chapters, 5 cells, total 01:30:00 @ 25fps
    //   Chapters: 20:00, 15:00, 25:00, 10:00, 20:00
    //
    // Title 2 (VTS-TTN 2): 2 chapters, 2 cells, total 00:10:00 @ 25fps
    //   Chapters: 06:00, 04:00
    // ========================================================================
    fn build_test_vts_ifo() -> Vec<u8> {
        let mut d = vec![0u8; 8192]; // 4 sectors

        // ----------------------------------------------------------------
        // VTSI_MAT (sector 0)
        // ----------------------------------------------------------------
        d[0..12].copy_from_slice(b"DVDVIDEO-VTS");
        put_u32(&mut d, VTSI_VTS_PTT_SRPT_SECTOR, 1); // PTT_SRPT in sector 1
        put_u32(&mut d, VTSI_VTS_PGCIT_SECTOR, 2);     // PGCIT in sector 2

        // Video: MPEG-2, NTSC, 16:9, 720x480
        d[VTSI_VTS_VIDEO_ATTR]     = 0b01_00_11_00;
        d[VTSI_VTS_VIDEO_ATTR + 1] = 0b0000_00_00;

        // 2 audio streams
        d[VTSI_NR_OF_VTS_AUDIO] = 2;

        // Audio 0: AC3, 48 kHz, English, 5.1
        let a0 = VTSI_VTS_AUDIO_ATTR;
        d[a0]     = 0b000_0_00_00; // AC3
        d[a0 + 1] = 0b00_00_0000; // 48 kHz
        d[a0 + 2] = b'e';
        d[a0 + 3] = b'n';
        d[a0 + 7] = 5; // channels − 1

        // Audio 1: DTS, 48 kHz, French, stereo
        let a1 = a0 + AUDIO_ATTR_SIZE;
        d[a1]     = 0b110_0_00_00; // DTS
        d[a1 + 1] = 0b00_00_0000; // 48 kHz
        d[a1 + 2] = b'f';
        d[a1 + 3] = b'r';
        d[a1 + 7] = 1; // channels − 1

        // ----------------------------------------------------------------
        // VTS_PTT_SRPT (sector 1, byte 2048)
        // 2 titles in this VTS
        // ----------------------------------------------------------------
        let ptt = 1 * DVD_BLOCK_LEN;
        put_u16(&mut d, ptt + VTS_PTT_SRPT_NR_OF_TITLES, 2);

        // Offset table: one u32 per title, starting at ptt + 8
        //   Title 1 PTTs start at byte offset 16 from PTT_SRPT start
        //   Title 2 PTTs start after title 1's 5 entries (5*4 = 20 bytes later)
        let title1_ptt_off: u32 = 16; // 8 (header) + 2*4 (offset table) = 16
        let title2_ptt_off: u32 = title1_ptt_off + 5 * 4; // 5 chapters * 4 bytes = 36
        put_u32(&mut d, ptt + VTS_PTT_SRPT_OFFSETS_START, title1_ptt_off);
        put_u32(&mut d, ptt + VTS_PTT_SRPT_OFFSETS_START + 4, title2_ptt_off);

        // Title 1 PTT entries: 5 chapters, all pointing to PGC 1
        let t1_ptt = ptt + title1_ptt_off as usize;
        for ch in 0u16..5 {
            let e = t1_ptt + (ch as usize) * 4;
            put_u16(&mut d, e, 1);        // PGCN = 1
            put_u16(&mut d, e + 2, ch + 1); // PGN = 1..5
        }

        // Title 2 PTT entries: 2 chapters, all pointing to PGC 2
        let t2_ptt = ptt + title2_ptt_off as usize;
        for ch in 0u16..2 {
            let e = t2_ptt + (ch as usize) * 4;
            put_u16(&mut d, e, 2);        // PGCN = 2
            put_u16(&mut d, e + 2, ch + 1); // PGN = 1..2
        }

        // ----------------------------------------------------------------
        // VTS_PGCIT (sector 2, byte 4096)
        // 2 PGC entries
        // ----------------------------------------------------------------
        let pgcit = 2 * DVD_BLOCK_LEN;
        put_u16(&mut d, pgcit + PGCIT_NR_OF_PGCI_SRP, 2);

        // PGCI_SRP entry 1: PGC at byte offset 24 from PGCIT start
        //   (header 8 + 2 entries * 8 = 24)
        let pgci1 = pgcit + PGCIT_ENTRIES_START;
        put_u32(&mut d, pgci1 + PGCI_SRP_PGC_START_BYTE, 24);

        // PGCI_SRP entry 2: PGC at byte offset 24 + 0xF0 + 5*24 = 24+240+120 = 384
        //   (after PGC 1's fixed header + program_map(5) + padding(3) + cell_playback(5*24))
        let pgc1_size = 0xF8 + 5 * CELL_PLAYBACK_SIZE; // 248 + 120 = 368
        let pgci2 = pgcit + PGCIT_ENTRIES_START + PGCI_SRP_SIZE;
        put_u32(&mut d, pgci2 + PGCI_SRP_PGC_START_BYTE, 24 + pgc1_size as u32);

        // ----------------------------------------------------------------
        // PGC 1 (title 1): 5 programs, 5 cells, 01:30:00 @ 25 fps
        // ----------------------------------------------------------------
        let pgc1 = pgcit + 24;
        d[pgc1 + PGC_NR_OF_PROGRAMS] = 5;
        d[pgc1 + PGC_NR_OF_CELLS] = 5;

        // Playback time: 01:30:00.00 @ 25 fps
        d[pgc1 + PGC_PLAYBACK_TIME]     = 0x01; // hours BCD
        d[pgc1 + PGC_PLAYBACK_TIME + 1] = 0x30; // minutes BCD
        d[pgc1 + PGC_PLAYBACK_TIME + 2] = 0x00; // seconds BCD
        d[pgc1 + PGC_PLAYBACK_TIME + 3] = 0b01_000000; // 25 fps, 0 frames

        // program_map at PGC + 0xEC (right after the fixed 0xEC-byte header)
        put_u16(&mut d, pgc1 + PGC_PROGRAM_MAP_OFFSET, 0xEC);
        let pm1 = pgc1 + 0xEC;
        d[pm1]     = 1; // program 1 → cell 1
        d[pm1 + 1] = 2; // program 2 → cell 2
        d[pm1 + 2] = 3; // program 3 → cell 3
        d[pm1 + 3] = 4; // program 4 → cell 4
        d[pm1 + 4] = 5; // program 5 → cell 5

        // cell_playback at PGC + 0xF8 (after 5-byte program_map + 7 bytes padding)
        put_u16(&mut d, pgc1 + PGC_CELL_PLAYBACK_OFFSET, 0xF8);
        let cp1 = pgc1 + 0xF8;

        // Chapter durations: 20:00, 15:00, 25:00, 10:00, 20:00  (sum = 90:00)
        let chapter_times_bcd: [(u8, u8, u8); 5] = [
            (0x00, 0x20, 0x00), // 20 min
            (0x00, 0x15, 0x00), // 15 min
            (0x00, 0x25, 0x00), // 25 min
            (0x00, 0x10, 0x00), // 10 min
            (0x00, 0x20, 0x00), // 20 min
        ];
        for (i, (h, m, s)) in chapter_times_bcd.iter().enumerate() {
            let c = cp1 + i * CELL_PLAYBACK_SIZE;
            d[c + CELL_PLAYBACK_TIME]     = *h;
            d[c + CELL_PLAYBACK_TIME + 1] = *m;
            d[c + CELL_PLAYBACK_TIME + 2] = *s;
            d[c + CELL_PLAYBACK_TIME + 3] = 0b01_000000; // 25 fps
        }

        // ----------------------------------------------------------------
        // PGC 2 (title 2): 2 programs, 2 cells, 00:10:00 @ 25 fps
        // ----------------------------------------------------------------
        let pgc2 = pgcit + 24 + pgc1_size;
        d[pgc2 + PGC_NR_OF_PROGRAMS] = 2;
        d[pgc2 + PGC_NR_OF_CELLS] = 2;

        // Playback time: 00:10:00.00 @ 25 fps
        d[pgc2 + PGC_PLAYBACK_TIME]     = 0x00;
        d[pgc2 + PGC_PLAYBACK_TIME + 1] = 0x10;
        d[pgc2 + PGC_PLAYBACK_TIME + 2] = 0x00;
        d[pgc2 + PGC_PLAYBACK_TIME + 3] = 0b01_000000;

        put_u16(&mut d, pgc2 + PGC_PROGRAM_MAP_OFFSET, 0xEC);
        let pm2 = pgc2 + 0xEC;
        d[pm2]     = 1;
        d[pm2 + 1] = 2;

        put_u16(&mut d, pgc2 + PGC_CELL_PLAYBACK_OFFSET, 0xF0);
        let cp2 = pgc2 + 0xF0;

        // Chapter durations: 06:00, 04:00  (sum = 10:00)
        let ch2_times: [(u8, u8, u8); 2] = [
            (0x00, 0x06, 0x00),
            (0x00, 0x04, 0x00),
        ];
        for (i, (h, m, s)) in ch2_times.iter().enumerate() {
            let c = cp2 + i * CELL_PLAYBACK_SIZE;
            d[c + CELL_PLAYBACK_TIME]     = *h;
            d[c + CELL_PLAYBACK_TIME + 1] = *m;
            d[c + CELL_PLAYBACK_TIME + 2] = *s;
            d[c + CELL_PLAYBACK_TIME + 3] = 0b01_000000;
        }

        d
    }

    /// End-to-end test: create a synthetic VIDEO_TS folder with valid IFO
    /// binary data, then run enumerate_titles and verify every parsed field.
    #[test]
    fn test_enumerate_titles_from_video_ts_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let video_ts = tmp.path().join("VIDEO_TS");
        std::fs::create_dir(&video_ts).unwrap();

        std::fs::write(video_ts.join("VIDEO_TS.IFO"), build_test_vmg_ifo()).unwrap();
        std::fs::write(video_ts.join("VTS_01_0.IFO"), build_test_vts_ifo()).unwrap();

        let info = enumerate_titles(tmp.path().to_str().unwrap()).unwrap();

        // -- Volume label comes from directory name --
        assert!(!info.volume_label.is_empty());

        // -- 2 titles, sorted longest-first --
        assert_eq!(info.titles.len(), 2);

        let long = &info.titles[0]; // title 1, ~90 min
        let short = &info.titles[1]; // title 2, ~10 min
        assert!(long.duration_seconds > short.duration_seconds);

        // -- Title 1: video attributes --
        assert_eq!(long.index, 1);
        assert_eq!(long.width, 720);
        assert_eq!(long.height, 480);
        assert_eq!(long.aspect_ratio, "16:9");
        assert!((long.frame_rate - 25.0).abs() < 0.1);
        assert_eq!(long.angles, 1);
        assert_eq!(long.vts_number, 1);

        // -- Title 1: duration (01:30:00 = 5400s) --
        assert!(
            (long.duration_seconds - 5400.0).abs() < 1.0,
            "expected ~5400s, got {}",
            long.duration_seconds
        );

        // -- Title 1: 5 chapters with correct durations --
        assert_eq!(long.chapters.len(), 5);
        let expected_ch_secs = [1200.0, 900.0, 1500.0, 600.0, 1200.0]; // 20,15,25,10,20 min
        for (ch, &expected) in long.chapters.iter().zip(&expected_ch_secs) {
            assert!(
                (ch.duration_seconds - expected).abs() < 1.0,
                "chapter {} expected ~{}s, got {}s",
                ch.index,
                expected,
                ch.duration_seconds
            );
        }

        // -- Title 1: 2 audio tracks --
        assert_eq!(long.audio_tracks.len(), 2);

        assert_eq!(long.audio_tracks[0].index, 0);
        assert_eq!(long.audio_tracks[0].language, "en");
        assert_eq!(long.audio_tracks[0].format, "AC3");
        assert_eq!(long.audio_tracks[0].channels, 6);
        assert_eq!(long.audio_tracks[0].sample_rate, 48000);

        assert_eq!(long.audio_tracks[1].index, 1);
        assert_eq!(long.audio_tracks[1].language, "fr");
        assert_eq!(long.audio_tracks[1].format, "DTS");
        assert_eq!(long.audio_tracks[1].channels, 2);

        // -- Title 2: shorter, 2 chapters --
        assert_eq!(short.index, 2);
        assert!(
            (short.duration_seconds - 600.0).abs() < 1.0,
            "expected ~600s, got {}",
            short.duration_seconds
        );
        assert_eq!(short.chapters.len(), 2);
        assert!((short.chapters[0].duration_seconds - 360.0).abs() < 1.0); // 6 min
        assert!((short.chapters[1].duration_seconds - 240.0).abs() < 1.0); // 4 min

        // -- Both titles share the same VTS, so same video/audio attrs --
        assert_eq!(short.width, 720);
        assert_eq!(short.audio_tracks.len(), 2);
    }

    /// The same enumeration, but from a flat rip: the IFOs sit directly in a
    /// folder named after the disc, with no VIDEO_TS directory. Proves the whole
    /// title-reading path works for that shape, not just the directory lookup.
    #[test]
    fn test_enumerate_titles_from_flat_rip_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let disc = tmp.path().join("Wedding 1998");
        std::fs::create_dir(&disc).unwrap();

        std::fs::write(disc.join("VIDEO_TS.IFO"), build_test_vmg_ifo()).unwrap();
        std::fs::write(disc.join("VTS_01_0.IFO"), build_test_vts_ifo()).unwrap();
        std::fs::write(disc.join("VTS_01_1.VOB"), b"").unwrap();

        let info = enumerate_titles(disc.to_str().unwrap()).unwrap();

        // The folder name is the disc name here, so it becomes the volume label.
        assert_eq!(info.volume_label, "Wedding 1998");
        assert_eq!(info.titles.len(), 2);
        assert!((info.titles[0].duration_seconds - 5400.0).abs() < 1.0);
        assert_eq!(info.titles[0].width, 720);
    }

    // ========================================================================
    // Title → cells → sectors (task #27)
    // ========================================================================

    /// A cell for `VtsBuilder`: (flags byte, seconds, first sector, last sector).
    #[derive(Clone, Copy)]
    struct TCell(u8, u32, u32, u32);

    const NORMAL: u8 = 0;
    const ANGLE_FIRST: u8 = 0b01_01_0000;
    const ANGLE_MID: u8 = 0b10_01_0000;
    const ANGLE_LAST: u8 = 0b11_01_0000;

    struct TPgc {
        program_map: Vec<u8>,
        cells: Vec<TCell>,
    }

    /// Builds a VTS IFO from titles (each a list of (pgcn, pgn) chapters)
    /// and PGCs, at 25 fps.
    fn build_vts(titles: &[Vec<(u16, u16)>], pgcs: &[TPgc]) -> Vec<u8> {
        let mut d = vec![0u8; 16 * DVD_BLOCK_LEN];
        d[0..12].copy_from_slice(b"DVDVIDEO-VTS");
        put_u32(&mut d, VTSI_VTS_PTT_SRPT_SECTOR, 1);
        put_u32(&mut d, VTSI_VTS_PGCIT_SECTOR, 2);

        let ptt = DVD_BLOCK_LEN;
        put_u16(&mut d, ptt, titles.len() as u16);
        let mut off = 8 + 4 * titles.len();
        for (t, chapters) in titles.iter().enumerate() {
            put_u32(&mut d, ptt + 8 + 4 * t, off as u32);
            for &(pgcn, pgn) in chapters {
                put_u16(&mut d, ptt + off, pgcn);
                put_u16(&mut d, ptt + off + 2, pgn);
                off += 4;
            }
        }

        let pgcit = 2 * DVD_BLOCK_LEN;
        put_u16(&mut d, pgcit, pgcs.len() as u16);
        let mut pgc_rel = 8 + 8 * pgcs.len();
        for (i, pgc) in pgcs.iter().enumerate() {
            put_u32(&mut d, pgcit + 8 + 8 * i + PGCI_SRP_PGC_START_BYTE, pgc_rel as u32);
            let p = pgcit + pgc_rel;
            d[p + PGC_NR_OF_PROGRAMS] = pgc.program_map.len() as u8;
            d[p + PGC_NR_OF_CELLS] = pgc.cells.len() as u8;
            put_u16(&mut d, p + PGC_PROGRAM_MAP_OFFSET, 0xEC);
            d[p + 0xEC..p + 0xEC + pgc.program_map.len()].copy_from_slice(&pgc.program_map);
            let table = 0xEC + ((pgc.program_map.len() + 1) & !1);
            put_u16(&mut d, p + PGC_CELL_PLAYBACK_OFFSET, table as u16);
            for (c, cell) in pgc.cells.iter().enumerate() {
                let e = p + table + c * CELL_PLAYBACK_SIZE;
                d[e] = cell.0;
                let secs = cell.1;
                d[e + CELL_PLAYBACK_TIME] = 0;
                d[e + CELL_PLAYBACK_TIME + 1] = ((secs / 60 / 10) << 4 | (secs / 60 % 10)) as u8;
                d[e + CELL_PLAYBACK_TIME + 2] = ((secs % 60 / 10) << 4 | (secs % 60 % 10)) as u8;
                d[e + CELL_PLAYBACK_TIME + 3] = 0b01_000000;
                put_u32(&mut d, e + CELL_FIRST_SECTOR, cell.2);
                put_u32(&mut d, e + CELL_LAST_SECTOR, cell.3);
            }
            pgc_rel += table + pgc.cells.len() * CELL_PLAYBACK_SIZE;
        }
        d
    }

    fn entry(vts_ttn: u8, nr_of_ptts: u16, nr_of_angles: u8) -> TitleEntry {
        TitleEntry { nr_of_angles, nr_of_ptts, title_set_nr: 1, vts_ttn }
    }

    fn sectors(cells: &[CellRef]) -> Vec<(u32, u32)> {
        cells.iter().map(|c| (c.first_sector, c.last_sector)).collect()
    }

    /// A TV-series-shaped title set: two episodes as titles of one VTS, the
    /// second with three chapters in one PGC.
    fn two_episode_vts() -> Vec<u8> {
        build_vts(
            &[vec![(1, 1)], vec![(2, 1), (2, 2), (2, 3)]],
            &[
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 60, 0, 999)] },
                TPgc {
                    program_map: vec![1, 2, 4],
                    cells: vec![
                        TCell(NORMAL, 10, 1000, 1099),
                        TCell(NORMAL, 20, 1100, 1299),
                        TCell(NORMAL, 5, 1300, 1349),
                        TCell(NORMAL, 30, 1350, 1649),
                    ],
                },
            ],
        )
    }

    #[test]
    fn title_cells_take_only_the_titles_own_cells() {
        let vts = two_episode_vts();
        let one = title_cells(&vts, &entry(1, 1, 1), None, 1).unwrap();
        assert_eq!(sectors(&one), [(0, 999)]);

        let two = title_cells(&vts, &entry(2, 3, 1), None, 1).unwrap();
        assert_eq!(sectors(&two), [(1000, 1099), (1100, 1299), (1300, 1349), (1350, 1649)]);
        assert_eq!(two.iter().map(|c| c.chapter).collect::<Vec<_>>(), [1, 2, 2, 3]);
        assert!(two.iter().all(|c| c.pgcn == 2));
        assert!((two.iter().map(|c| c.seconds).sum::<f64>() - 65.0).abs() < 0.01);
    }

    #[test]
    fn title_cells_honour_a_chapter_range() {
        let vts = two_episode_vts();
        let t = entry(2, 3, 1);
        let range = title_cells(&vts, &t, Some((2, 3)), 1).unwrap();
        assert_eq!(sectors(&range), [(1100, 1299), (1300, 1349), (1350, 1649)]);
        let single = title_cells(&vts, &t, Some((2, 2)), 1).unwrap();
        assert_eq!(sectors(&single), [(1100, 1299), (1300, 1349)]);
        let first = title_cells(&vts, &t, Some((1, 1)), 1).unwrap();
        assert_eq!(sectors(&first), [(1000, 1099)]);
    }

    #[test]
    fn title_cells_refuse_chapters_and_angles_the_title_lacks() {
        let vts = two_episode_vts();
        let t = entry(2, 3, 1);
        let err = |r: Result<Vec<CellRef>>| r.unwrap_err().to_string();
        assert_eq!(err(title_cells(&vts, &t, Some((2, 5)), 1)), "the title has 3 chapters; asked for 2-5");
        assert!(err(title_cells(&vts, &t, Some((0, 2)), 1)).contains("asked for 0-2"));
        assert!(err(title_cells(&vts, &t, Some((3, 2)), 1)).contains("asked for 3-2"));
        assert!(err(title_cells(&vts, &t, None, 2)).contains("1 angle(s); asked for angle 2"));
        assert!(err(title_cells(&vts, &t, None, 0)).contains("asked for angle 0"));
        assert!(title_cells(&vts, &entry(3, 1, 1), None, 1).is_err(), "no third title in the VTS");
    }

    /// Some discs give every chapter its own PGC.
    #[test]
    fn title_cells_follow_one_pgc_per_chapter() {
        let vts = build_vts(
            &[vec![(1, 1), (2, 1), (3, 1)]],
            &[
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 10, 0, 99)] },
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 10, 100, 199), TCell(NORMAL, 5, 200, 249)] },
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 10, 250, 349)] },
            ],
        );
        let t = entry(1, 3, 1);
        let all = title_cells(&vts, &t, None, 1).unwrap();
        assert_eq!(sectors(&all), [(0, 99), (100, 199), (200, 249), (250, 349)]);
        assert_eq!(all.iter().map(|c| c.pgcn).collect::<Vec<_>>(), [1, 2, 2, 3]);
        assert_eq!(sectors(&title_cells(&vts, &t, Some((2, 3)), 1).unwrap()), [(100, 199), (200, 249), (250, 349)]);
    }

    /// Chapters play in PTT order, which need not be program order.
    #[test]
    fn title_cells_follow_the_ptt_order() {
        let vts = build_vts(
            &[vec![(1, 2), (1, 1)]],
            &[TPgc {
                program_map: vec![1, 2],
                cells: vec![TCell(NORMAL, 10, 0, 99), TCell(NORMAL, 10, 100, 199)],
            }],
        );
        let cells = title_cells(&vts, &entry(1, 2, 1), None, 1).unwrap();
        assert_eq!(sectors(&cells), [(100, 199), (0, 99)]);
        assert_eq!(cells.iter().map(|c| c.chapter).collect::<Vec<_>>(), [1, 2]);
    }

    /// A PGC can hold more programs than the title has chapters: a program
    /// no chapter starts at belongs to the chapter before it (a player plays
    /// it), so it is copied with that chapter rather than dropped.
    #[test]
    fn title_cells_keep_programs_no_chapter_starts_at() {
        let vts = build_vts(
            &[vec![(1, 1), (1, 3)]],
            &[TPgc {
                program_map: vec![1, 2, 3, 4],
                cells: vec![
                    TCell(NORMAL, 10, 0, 99),
                    TCell(NORMAL, 10, 100, 199),
                    TCell(NORMAL, 10, 200, 299),
                    TCell(NORMAL, 10, 300, 399),
                ],
            }],
        );
        let t = entry(1, 2, 1);
        let all = title_cells(&vts, &t, None, 1).unwrap();
        assert_eq!(all.iter().map(|c| c.cell).collect::<Vec<_>>(), [1, 2, 3, 4]);
        assert_eq!(all.iter().map(|c| c.chapter).collect::<Vec<_>>(), [1, 1, 2, 2]);
        assert_eq!(sectors(&title_cells(&vts, &t, Some((1, 1)), 1).unwrap()), [(0, 99), (100, 199)]);
        assert_eq!(sectors(&title_cells(&vts, &t, Some((2, 2)), 1).unwrap()), [(200, 299), (300, 399)]);
    }

    #[test]
    fn title_cells_take_one_cell_of_an_angle_block() {
        let vts = build_vts(
            &[vec![(1, 1), (1, 2)]],
            &[TPgc {
                program_map: vec![1, 5],
                cells: vec![
                    TCell(NORMAL, 10, 0, 99),
                    TCell(ANGLE_FIRST, 20, 100, 199),
                    TCell(ANGLE_MID, 20, 200, 299),
                    TCell(ANGLE_LAST, 20, 300, 399),
                    TCell(NORMAL, 10, 400, 499),
                ],
            }],
        );
        let t = entry(1, 2, 3);
        let one = title_cells(&vts, &t, None, 1).unwrap();
        assert_eq!(one.iter().map(|c| c.cell).collect::<Vec<_>>(), [1, 2, 5]);
        assert_eq!(one[1].angles_in_block, 3);
        let three = title_cells(&vts, &t, None, 3).unwrap();
        assert_eq!(three.iter().map(|c| c.cell).collect::<Vec<_>>(), [1, 4, 5]);
        assert_eq!(sectors(&three), [(0, 99), (300, 399), (400, 499)]);
        // One angle's time, not three.
        assert!((one.iter().map(|c| c.seconds).sum::<f64>() - 40.0).abs() < 0.01);
        assert!(title_cells(&vts, &entry(1, 2, 4), None, 4).unwrap_err().to_string().contains("has 3 angles"));
        assert!(title_cells(&vts, &t, None, 4).is_err());
    }

    /// A seamless angle block's cells are flagged interleaved and planned as
    /// a NAV walk, never as a range (the range spans every angle).
    #[test]
    fn title_cells_flag_interleaved_angle_cells() {
        const IL: u8 = 0b0000_0100;
        let vts = build_vts(
            &[vec![(1, 1)]],
            &[TPgc {
                program_map: vec![1],
                cells: vec![
                    TCell(NORMAL, 10, 0, 99),
                    TCell(ANGLE_FIRST | IL, 20, 100, 399),
                    TCell(ANGLE_LAST | IL, 20, 108, 399),
                ],
            }],
        );
        let cells = title_cells(&vts, &entry(1, 1, 2), None, 2).unwrap();
        assert_eq!(cells.iter().map(|c| c.interleaved).collect::<Vec<_>>(), [false, true]);
        assert_eq!(
            copy_plan(&cells),
            [Segment::Range { first: 0, last: 99 }, Segment::Interleaved { first: 108, last: 399, angles: 2 }]
        );
    }

    #[test]
    fn copy_plan_merges_touching_cells_only() {
        let cell = |first, last, interleaved| CellRef {
            chapter: 1, pgcn: 1, cell: 1, first_sector: first, last_sector: last,
            interleaved, angles_in_block: if interleaved { 2 } else { 1 }, seconds: 0.0,
        };
        let plan = copy_plan(&[
            cell(0, 99, false),
            cell(100, 199, false),   // touches: merged
            cell(300, 399, false),   // gap: new range
            cell(300, 399, false),   // played twice: copied twice
            cell(400, 599, true),    // interleaved: never merged
            cell(600, 699, false),
        ]);
        assert_eq!(
            plan,
            [
                Segment::Range { first: 0, last: 199 },
                Segment::Range { first: 300, last: 399 },
                Segment::Range { first: 300, last: 399 },
                Segment::Interleaved { first: 400, last: 599, angles: 2 },
                Segment::Range { first: 600, last: 699 },
            ]
        );
        assert_eq!(estimated_blocks(&plan), 200 + 100 + 100 + 100 + 100);
    }

    /// A NAV pack at `lbn`: VOBU of `vobu_ea + 1` sectors, next VOBU
    /// `next_vobu` sectors on.
    fn nav_pack(lbn: u32, vobu_ea: u32, next_vobu: u32, vob_id: u16) -> Vec<u8> {
        let mut b = vec![0u8; DVD_BLOCK_LEN];
        b[0..4].copy_from_slice(&[0, 0, 1, 0xBA]);
        b[0x26..0x2A].copy_from_slice(&[0, 0, 1, 0xBF]);
        b[0x400..0x404].copy_from_slice(&[0, 0, 1, 0xBF]);
        b[0x406] = 0x01;
        put_u32(&mut b, NAV_DSI_START + DSI_NV_PCK_LBN, lbn);
        put_u32(&mut b, NAV_DSI_START + DSI_VOBU_EA, vobu_ea);
        put_u16(&mut b, NAV_DSI_START + DSI_VOBU_VOB_IDN, vob_id);
        b[NAV_DSI_START + DSI_VOBU_C_IDN] = 1;
        put_u32(&mut b, NAV_DSI_START + DSI_VOBU_SRI_NEXT_VOBU, next_vobu);
        b
    }

    #[test]
    fn parse_nav_dsi_reads_the_dsi_and_rejects_other_packs() {
        let dsi = parse_nav_dsi(&nav_pack(1234, 17, 0x8000_0012, 7)).unwrap();
        assert_eq!(dsi, Dsi { nv_pck_lbn: 1234, vobu_ea: 17, vobu_vob_idn: 7, vobu_c_idn: 1, next_vobu: 0x8000_0012 });
        let mut video = vec![0u8; DVD_BLOCK_LEN];
        video[0..4].copy_from_slice(&[0, 0, 1, 0xBA]);
        assert!(parse_nav_dsi(&video).is_err());
        assert!(parse_nav_dsi(&[0u8; 100]).is_err());
    }

    /// An in-memory disc: sector n is `blocks[n]` (or filler).
    struct MemDisc {
        blocks: Vec<Vec<u8>>,
        fail_from: Option<u32>,
    }

    impl BlockSource for MemDisc {
        fn read(&mut self, offset: u32, count: usize, buf: &mut [u8]) -> isize {
            let mut n = 0;
            while n < count && (offset as usize + n) < self.blocks.len() {
                if self.fail_from.is_some_and(|f| offset as usize + n >= f as usize) {
                    break;
                }
                buf[n * DVD_BLOCK_LEN..(n + 1) * DVD_BLOCK_LEN].copy_from_slice(&self.blocks[offset as usize + n]);
                n += 1;
            }
            if n == 0 { -1 } else { n as isize }
        }
    }

    /// Two angles interleaved in ILVUs of two 4-sector VOBUs each:
    /// A A B B A A B B from sector 10, every VOBU's NAV pointing at its
    /// angle's next VOBU (the other angle's unit skipped).
    fn interleaved_disc() -> MemDisc {
        let filler = |tag: u8| vec![tag; DVD_BLOCK_LEN];
        let mut blocks: Vec<Vec<u8>> = (0..10).map(|_| filler(0xEE)).collect();
        // VOBU starts: A 10, A 14, B 18, B 22, A 26, A 30, B 34, B 38
        let layout = [(10u32, 'A', 4u32), (14, 'A', 12), (18, 'B', 4), (22, 'B', 12),
                      (26, 'A', 4), (30, 'A', SRI_END_OF_CELL), (34, 'B', 4), (38, 'B', SRI_END_OF_CELL)];
        for (lbn, angle, next) in layout {
            let tag = if angle == 'A' { 0xAA } else { 0xBB };
            let id = if angle == 'A' { 1 } else { 2 };
            let next = if next == SRI_END_OF_CELL { next } else { 0x8000_0000 | next };
            blocks.push(nav_pack(lbn, 3, next, id));
            for _ in 0..3 {
                blocks.push(filler(tag));
            }
        }
        MemDisc { blocks, fail_from: None }
    }

    #[test]
    fn walk_interleaved_keeps_to_one_angle() {
        let mut disc = interleaved_disc();
        let mut read = |s: u32| -> Result<Vec<u8>> {
            let mut b = vec![0u8; DVD_BLOCK_LEN];
            anyhow::ensure!(disc.read(s, 1, &mut b) == 1);
            Ok(b)
        };
        // Angle A's cell spans the whole interleaved region.
        assert_eq!(walk_interleaved(10, 41, &mut read).unwrap(), [(10, 17), (26, 33)]);
        // Angle B's cell starts at its first unit.
        assert_eq!(walk_interleaved(18, 41, &mut read).unwrap(), [(18, 25), (34, 41)]);
    }

    #[test]
    fn walk_interleaved_refuses_what_it_cannot_follow() {
        let mut blocks = vec![nav_pack(0, 3, 0x8000_0000, 1)];
        blocks.extend((0..3).map(|_| vec![0u8; DVD_BLOCK_LEN]));
        let read = |s: u32| -> Result<Vec<u8>> { Ok(blocks[s as usize].clone()) };
        assert!(walk_interleaved(0, 3, read).unwrap_err().to_string().contains("does not advance"));

        let wrong_lbn = vec![nav_pack(5, 3, SRI_END_OF_CELL, 1)];
        let read = |s: u32| -> Result<Vec<u8>> { Ok(wrong_lbn[s as usize].clone()) };
        assert!(walk_interleaved(0, 3, read).unwrap_err().to_string().contains("says it is at 5"));

        let not_nav = vec![vec![0u8; DVD_BLOCK_LEN]];
        let read = |s: u32| -> Result<Vec<u8>> { Ok(not_nav[s as usize].clone()) };
        assert!(walk_interleaved(0, 3, read).is_err());
    }

    #[test]
    fn copy_title_writes_exactly_the_planned_sectors() {
        let mut disc = interleaved_disc();
        // Sectors 0..9 carry their own number so order is checkable.
        for i in 0..10 {
            disc.blocks[i] = vec![i as u8; DVD_BLOCK_LEN];
        }
        let plan = [
            Segment::Range { first: 2, last: 3 },
            Segment::Interleaved { first: 18, last: 41, angles: 2 },
            Segment::Range { first: 0, last: 0 },
        ];
        let mut out = Vec::new();
        let mut last_progress = (0, 0);
        let stats = copy_title(&mut disc, &plan, &mut out, |d, t| last_progress = (d, t)).unwrap();
        assert_eq!(stats, CopyStats { blocks: 2 + 16 + 1, stopped_at: None });
        assert_eq!(out.len(), 19 * DVD_BLOCK_LEN);
        let sector = |i: usize| &out[i * DVD_BLOCK_LEN..(i + 1) * DVD_BLOCK_LEN];
        assert!(sector(0).iter().all(|&b| b == 2) && sector(1).iter().all(|&b| b == 3));
        for i in 2..18 {
            let s = sector(i);
            assert!(s[0..4] == [0, 0, 1, 0xBA] || s.iter().all(|&b| b == 0xBB), "sector {} is not angle B", i);
        }
        assert!(sector(18).iter().all(|&b| b == 0));
        assert_eq!(last_progress.0, 19);
        assert!(last_progress.1 >= 19);
    }

    #[test]
    fn copy_title_stops_at_a_bad_sector_after_data_but_fails_before() {
        let mut disc = MemDisc { blocks: (0..10).map(|_| vec![1u8; DVD_BLOCK_LEN]).collect(), fail_from: Some(5) };
        let mut out = Vec::new();
        let stats = copy_title(&mut disc, &[Segment::Range { first: 0, last: 9 }], &mut out, |_, _| {}).unwrap();
        assert_eq!(stats, CopyStats { blocks: 5, stopped_at: Some(5) });

        let mut out = Vec::new();
        assert!(copy_title(&mut disc, &[Segment::Range { first: 6, last: 9 }], &mut out, |_, _| {}).is_err());
    }

    /// The picker's durations come from the same cells: one angle's time,
    /// and every chapter's own PGC.
    #[test]
    fn enumerate_titles_counts_one_angle_and_every_pgc() {
        let tmp = tempfile::tempdir().unwrap();
        let video_ts = tmp.path().join("VIDEO_TS");
        std::fs::create_dir(&video_ts).unwrap();

        let mut vmg = build_test_vmg_ifo();
        let tt = DVD_BLOCK_LEN + TT_SRPT_ENTRIES_START;
        vmg[tt + TITLE_NR_OF_ANGLES] = 3; // title 1: the angle title, 2 chapters
        put_u16(&mut vmg, tt + TITLE_NR_OF_PTTS, 2);
        let t2 = tt + TT_SRPT_ENTRY_SIZE; // title 2: one PGC per chapter, 3 chapters
        put_u16(&mut vmg, t2 + TITLE_NR_OF_PTTS, 3);
        std::fs::write(video_ts.join("VIDEO_TS.IFO"), vmg).unwrap();

        let vts = build_vts(
            &[vec![(1, 1), (1, 2)], vec![(2, 1), (3, 1), (4, 1)]],
            &[
                TPgc {
                    program_map: vec![1, 5],
                    cells: vec![
                        TCell(NORMAL, 10, 0, 99),
                        TCell(ANGLE_FIRST, 20, 100, 199),
                        TCell(ANGLE_MID, 20, 200, 299),
                        TCell(ANGLE_LAST, 20, 300, 399),
                        TCell(NORMAL, 10, 400, 499),
                    ],
                },
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 60, 500, 599)] },
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 70, 600, 699)] },
                TPgc { program_map: vec![1], cells: vec![TCell(NORMAL, 80, 700, 799)] },
            ],
        );
        std::fs::write(video_ts.join("VTS_01_0.IFO"), vts).unwrap();

        let info = enumerate_titles(tmp.path().to_str().unwrap()).unwrap();
        let by_index = |i| info.titles.iter().find(|t| t.index == i).unwrap();
        let angles = by_index(1);
        // Program 1 is cells 1-4 (10 s + one 20 s angle), program 2 cell 5.
        assert_eq!(angles.chapters.iter().map(|c| c.duration_seconds.round()).collect::<Vec<_>>(), [30.0, 10.0]);
        assert!((angles.duration_seconds - 40.0).abs() < 0.01);
        let per_pgc = by_index(2);
        assert_eq!(per_pgc.chapters.iter().map(|c| c.duration_seconds.round()).collect::<Vec<_>>(), [60.0, 70.0, 80.0]);
        assert!((per_pgc.duration_seconds - 210.0).abs() < 0.01);
    }

    /// The committed dvdauthor fixture (Tests/TestResources/
    /// generate_dvd_titles_test.sh) read the way an unencrypted folder reaches
    /// libdvdread's title VOBs: VTS_01_1.VOB onward, back to back.
    struct VobSet(Vec<u8>);

    impl VobSet {
        fn open(video_ts: &Path) -> Self {
            let mut bytes = Vec::new();
            for n in 1..=9 {
                match std::fs::read(video_ts.join(format!("VTS_01_{}.VOB", n))) {
                    Ok(b) => bytes.extend(b),
                    Err(_) => break,
                }
            }
            VobSet(bytes)
        }
    }

    impl BlockSource for VobSet {
        fn read(&mut self, offset: u32, count: usize, buf: &mut [u8]) -> isize {
            let start = offset as usize * DVD_BLOCK_LEN;
            if start >= self.0.len() {
                return -1;
            }
            let n = count.min((self.0.len() - start) / DVD_BLOCK_LEN);
            buf[..n * DVD_BLOCK_LEN].copy_from_slice(&self.0[start..start + n * DVD_BLOCK_LEN]);
            n as isize
        }
    }

    fn fixture_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Tests/TestResources/dvd_titles")
    }

    /// Extract (title, chapters) from the fixture without libdvdread; returns
    /// the output and the VOB IDs its NAV packs name.
    fn extract_fixture(title: u32, chapters: Option<(u16, u16)>) -> (Vec<u8>, Vec<u16>) {
        let dir = fixture_dir();
        let (entry, vts) = load_title(dir.to_str().unwrap(), title).unwrap();
        let plan = copy_plan(&title_cells(&vts, &entry, chapters, 1).unwrap());
        let mut out = Vec::new();
        let stats = copy_title(&mut VobSet::open(&dir.join("VIDEO_TS")), &plan, &mut out, |_, _| {}).unwrap();
        assert_eq!(stats.stopped_at, None);
        let mut ids: Vec<u16> = out
            .chunks(DVD_BLOCK_LEN)
            .filter_map(|b| parse_nav_dsi(b).ok())
            .map(|d| d.vobu_vob_idn)
            .collect();
        ids.dedup();
        (out, ids)
    }

    #[test]
    fn fixture_titles_are_copied_apart() {
        let vob_blocks = VobSet::open(&fixture_dir().join("VIDEO_TS")).0.len() / DVD_BLOCK_LEN;
        let (t1, ids1) = extract_fixture(1, None);
        let (t2, ids2) = extract_fixture(2, None);
        let (t3, ids3) = extract_fixture(3, None);

        // Every output starts on a NAV pack, and the three titles together
        // are the title set: nothing lost, nothing copied twice.
        for t in [&t1, &t2, &t3] {
            assert!(parse_nav_dsi(&t[..DVD_BLOCK_LEN]).is_ok());
        }
        assert_eq!((t1.len() + t2.len() + t3.len()) / DVD_BLOCK_LEN, vob_blocks);

        // One VOB per chapter: title 1 one, title 2 three, title 3 one, all distinct.
        assert_eq!((ids1.len(), ids2.len(), ids3.len()), (1, 3, 1));
        let mut all: Vec<u16> = ids1.iter().chain(&ids2).chain(&ids3).copied().collect();
        all.sort();
        all.dedup();
        assert_eq!(all.len(), 5);

        // A chapter range is the matching run of title 2's VOBs.
        let (_, ids23) = extract_fixture(2, Some((2, 3)));
        assert_eq!(ids23, ids2[1..]);
        let (_, ids2_2) = extract_fixture(2, Some((2, 2)));
        assert_eq!(ids2_2, ids2[1..2]);
    }
}
