//! DVD reading: IFO parsing for title enumeration and libdvdread FFI for extraction.
//!
//! Title enumeration reads IFO files directly from the filesystem (no library needed).
//! Title extraction uses libdvdread via dynamic loading for CSS decryption support.

use std::ffi::CString;
use std::os::raw::c_char;
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

// Cell playback entry (24 bytes each)
const CELL_PLAYBACK_SIZE: usize = 24;
const CELL_PLAYBACK_TIME: usize = 0x04;
#[allow(dead_code)]
const CELL_FIRST_SECTOR: usize = 0x08;
#[allow(dead_code)]
const CELL_LAST_SECTOR: usize = 0x14;

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

    bail!("VIDEO_TS directory not found at {:?}", path)
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
    let tt_srpt_sector = read_u32_be(&vmg_data, VMGI_TT_SRPT_SECTOR) as usize;

    // Parse TT_SRPT (title search pointer table)
    let tt_srpt_offset = tt_srpt_sector * DVD_BLOCK_LEN;
    if tt_srpt_offset >= vmg_data.len() {
        bail!("TT_SRPT sector offset out of bounds");
    }

    let nr_of_titles = read_u16_be(&vmg_data, tt_srpt_offset + TT_SRPT_NR_OF_TITLES) as usize;

    // Parse each title entry
    struct TitleEntry {
        nr_of_angles: u8,
        nr_of_ptts: u16,
        title_set_nr: u8,
        vts_ttn: u8,
    }

    let mut title_entries = Vec::new();
    for i in 0..nr_of_titles {
        let entry_offset = tt_srpt_offset + TT_SRPT_ENTRIES_START + i * TT_SRPT_ENTRY_SIZE;
        if entry_offset + TT_SRPT_ENTRY_SIZE > vmg_data.len() {
            break;
        }

        title_entries.push(TitleEntry {
            nr_of_angles: vmg_data[entry_offset + TITLE_NR_OF_ANGLES],
            nr_of_ptts: read_u16_be(&vmg_data, entry_offset + TITLE_NR_OF_PTTS),
            title_set_nr: vmg_data[entry_offset + TITLE_SET_NR],
            vts_ttn: vmg_data[entry_offset + TITLE_VTS_TTN],
        });
    }

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

        // Get title duration from PGC
        let (duration, frame_rate, chapters) =
            parse_title_pgc_info(vts_data, entry.vts_ttn, entry.nr_of_ptts)
                .unwrap_or((0.0, video.frame_rate, Vec::new()));

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

/// Parse PGC info for a specific title within a VTS IFO.
/// Returns (duration_seconds, frame_rate, chapters).
fn parse_title_pgc_info(
    vts_data: &[u8],
    vts_ttn: u8,
    nr_of_ptts: u16,
) -> Result<(f64, f64, Vec<DvdChapter>)> {
    let pgcit_sector = read_u32_be(vts_data, VTSI_VTS_PGCIT_SECTOR) as usize;
    let ptt_srpt_sector = read_u32_be(vts_data, VTSI_VTS_PTT_SRPT_SECTOR) as usize;

    if pgcit_sector == 0 || ptt_srpt_sector == 0 {
        bail!("Missing PGCIT or PTT_SRPT sector");
    }

    let pgcit_offset = pgcit_sector * DVD_BLOCK_LEN;
    let ptt_srpt_offset = ptt_srpt_sector * DVD_BLOCK_LEN;

    // Find the PGC number for this title via VTS_PTT_SRPT
    if ptt_srpt_offset >= vts_data.len() {
        bail!("PTT_SRPT offset out of bounds");
    }

    let nr_of_ptt_titles = read_u16_be(vts_data, ptt_srpt_offset + VTS_PTT_SRPT_NR_OF_TITLES) as usize;
    let vts_ttn_index = (vts_ttn as usize).saturating_sub(1);

    if vts_ttn_index >= nr_of_ptt_titles {
        bail!("VTS title number {} out of range (max {})", vts_ttn, nr_of_ptt_titles);
    }

    // Get offset to this title's PTT entries
    let title_offset_ptr = ptt_srpt_offset + VTS_PTT_SRPT_OFFSETS_START + vts_ttn_index * 4;
    let title_ptt_offset = read_u32_be(vts_data, title_offset_ptr) as usize;
    let ptt_entries_abs = ptt_srpt_offset + title_ptt_offset;

    if ptt_entries_abs >= vts_data.len() {
        bail!("PTT entries offset out of bounds");
    }

    // First PTT entry gives us the PGC number
    let pgcn = read_u16_be(vts_data, ptt_entries_abs) as usize; // PGC number (1-based)
    if pgcn == 0 {
        bail!("Invalid PGC number 0");
    }

    // Find PGC in PGCIT
    if pgcit_offset >= vts_data.len() {
        bail!("PGCIT offset out of bounds");
    }

    let nr_of_pgci_srp = read_u16_be(vts_data, pgcit_offset + PGCIT_NR_OF_PGCI_SRP) as usize;
    if pgcn > nr_of_pgci_srp {
        bail!("PGC number {} exceeds PGCIT entries ({})", pgcn, nr_of_pgci_srp);
    }

    let pgci_srp_offset = pgcit_offset + PGCIT_ENTRIES_START + (pgcn - 1) * PGCI_SRP_SIZE;
    let pgc_start_byte = read_u32_be(vts_data, pgci_srp_offset + PGCI_SRP_PGC_START_BYTE) as usize;
    let pgc_abs = pgcit_offset + pgc_start_byte;

    if pgc_abs + 0xEC > vts_data.len() {
        bail!("PGC data out of bounds");
    }

    // Parse PGC header
    let nr_of_programs = vts_data[pgc_abs + PGC_NR_OF_PROGRAMS] as usize;
    let nr_of_cells = vts_data[pgc_abs + PGC_NR_OF_CELLS] as usize;
    let total_duration = dvd_time_to_seconds(vts_data, pgc_abs + PGC_PLAYBACK_TIME);
    let frame_rate = dvd_time_frame_rate(vts_data, pgc_abs + PGC_PLAYBACK_TIME);

    // Parse chapter durations from cell playback data
    let chapters = parse_chapters(
        vts_data,
        pgc_abs,
        nr_of_programs,
        nr_of_cells,
        nr_of_ptts as usize,
    );

    Ok((total_duration, frame_rate, chapters))
}

/// Parse chapter durations from PGC program_map and cell_playback.
fn parse_chapters(
    vts_data: &[u8],
    pgc_abs: usize,
    nr_of_programs: usize,
    nr_of_cells: usize,
    nr_of_ptts: usize,
) -> Vec<DvdChapter> {
    let program_map_offset = read_u16_be(vts_data, pgc_abs + PGC_PROGRAM_MAP_OFFSET) as usize;
    let cell_playback_offset = read_u16_be(vts_data, pgc_abs + PGC_CELL_PLAYBACK_OFFSET) as usize;

    if program_map_offset == 0 || cell_playback_offset == 0 {
        // No program map or cell playback — return chapters with zero duration
        return (1..=nr_of_ptts)
            .map(|i| DvdChapter {
                index: i as u32,
                duration_seconds: 0.0,
            })
            .collect();
    }

    let program_map_abs = pgc_abs + program_map_offset;
    let cell_playback_abs = pgc_abs + cell_playback_offset;

    // Read program_map: array of u8 values (cell number where each program starts)
    let mut program_starts: Vec<usize> = Vec::new();
    for p in 0..nr_of_programs {
        if program_map_abs + p >= vts_data.len() {
            break;
        }
        program_starts.push(vts_data[program_map_abs + p] as usize);
    }

    // Calculate chapter durations by summing cell playback times per program
    let actual_chapters = nr_of_ptts.min(nr_of_programs);
    let mut chapters = Vec::new();

    for ch in 0..actual_chapters {
        let start_cell = if ch < program_starts.len() {
            program_starts[ch]
        } else {
            ch + 1
        };

        let end_cell = if ch + 1 < program_starts.len() {
            program_starts[ch + 1] - 1
        } else {
            nr_of_cells
        };

        let mut chapter_duration = 0.0;
        for cell in start_cell..=end_cell {
            let cell_idx = cell.saturating_sub(1); // cell numbers are 1-based
            let cell_offset = cell_playback_abs + cell_idx * CELL_PLAYBACK_SIZE;
            if cell_offset + CELL_PLAYBACK_SIZE <= vts_data.len() {
                chapter_duration += dvd_time_to_seconds(vts_data, cell_offset + CELL_PLAYBACK_TIME);
            }
        }

        chapters.push(DvdChapter {
            index: (ch + 1) as u32,
            duration_seconds: chapter_duration,
        });
    }

    chapters
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

        bail!(
            "libdvdread not found. DVD extraction requires libdvdread.\n\
             macOS: brew install libdvdread\n\
             Windows: place dvdread.dll in the application directory"
        )
    }
}

/// Extract a DVD title to an MPEG-PS file using libdvdread.
///
/// This reads the VOB data through libdvdread, which handles CSS decryption
/// if libdvdcss is installed.
pub fn extract_title(
    device_path: &str,
    title_index: u32,
    _start_chapter: Option<u32>,
    _end_chapter: Option<u32>,
    output_path: &Path,
    reporter: &ProgressReporter,
) -> Result<()> {
    // Load libdvdread
    let lib = DvdReadLib::load_auto()?;

    // Enumerate titles to find VTS info
    let dvd_info = enumerate_titles(device_path)?;

    let title = dvd_info
        .titles
        .iter()
        .find(|t| t.index == title_index)
        .with_context(|| format!("Title {} not found", title_index))?;

    let vts_nr = title.vts_number;

    reporter.send_log(
        crate::models::LogLevel::Info,
        &format!(
            "Extracting title {} (VTS {}) from {}",
            title_index, vts_nr, dvd_info.volume_label
        ),
    );

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

    // Get file size in blocks
    let total_blocks = unsafe { (lib.dvd_file_size)(dvd_file) };
    if total_blocks <= 0 {
        bail!("DVD file size is 0 for VTS {}", vts_nr);
    }

    reporter.send_log(
        crate::models::LogLevel::Info,
        &format!(
            "Reading {} blocks ({:.1} MB)",
            total_blocks,
            (total_blocks as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0)
        ),
    );

    // Read blocks and write to output file
    let mut output_file = std::fs::File::create(output_path)
        .with_context(|| format!("Failed to create output file {:?}", output_path))?;

    use std::io::Write;

    let batch_size = 128; // Read 128 blocks (256KB) at a time
    let mut buffer = vec![0u8; batch_size * DVD_BLOCK_LEN];
    let mut blocks_read_total: isize = 0;
    let mut offset = 0i32;
    let start_time = std::time::Instant::now();

    while blocks_read_total < total_blocks {
        let remaining = (total_blocks - blocks_read_total) as usize;
        let to_read = remaining.min(batch_size);

        let blocks_read = unsafe {
            (lib.dvd_read_blocks)(dvd_file, offset, to_read, buffer.as_mut_ptr())
        };

        if blocks_read <= 0 {
            if blocks_read_total > 0 {
                // Partial read is OK — some DVDs have unreadable sectors at the end
                reporter.send_log(
                    crate::models::LogLevel::Warning,
                    &format!(
                        "Read stopped at block {} of {} (partial extraction)",
                        blocks_read_total, total_blocks
                    ),
                );
                break;
            }
            bail!("Failed to read DVD blocks at offset {}", offset);
        }

        let bytes_to_write = blocks_read as usize * DVD_BLOCK_LEN;
        output_file
            .write_all(&buffer[..bytes_to_write])
            .context("Failed to write to output file")?;

        blocks_read_total += blocks_read;
        offset += blocks_read as i32;

        // Report progress
        let elapsed = start_time.elapsed().as_secs_f64();
        let progress_fraction = blocks_read_total as f64 / total_blocks as f64;
        let fps = if elapsed > 0.0 {
            blocks_read_total as f64 / elapsed
        } else {
            0.0
        };
        let eta = if fps > 0.0 {
            (total_blocks - blocks_read_total) as f64 / fps
        } else {
            0.0
        };

        let progress_info = crate::models::ProgressInfo::new(
            blocks_read_total as i32,
            total_blocks as i32,
            fps,
            eta,
        );
        reporter.send_progress_phase(&progress_info, "extracting");

        // Progress log every 10%
        let percent = (progress_fraction * 100.0) as i32;
        if percent > 0 && percent % 10 == 0 {
            let mb_done =
                (blocks_read_total as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0);
            reporter.send_log(
                crate::models::LogLevel::Debug,
                &format!("Extracted {:.1} MB ({}%)", mb_done, percent),
            );
        }
    }

    output_file
        .flush()
        .context("Failed to flush output file")?;

    let total_mb =
        (blocks_read_total as f64 * DVD_BLOCK_LEN as f64) / (1024.0 * 1024.0);
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
}
