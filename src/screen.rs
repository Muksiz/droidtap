//! What the terminal shows while recording.
//!
//! On a terminal this is a panel that is redrawn in place: the time, the
//! file, a level meter for each channel and the levels of the last seconds.
//! Anywhere else (a pipe, a log file) it is one plain line a minute.

use std::collections::VecDeque;
use std::fmt::Write as _;
use std::io::{self, IsTerminal, Write as _};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::{clock, size};

const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[0;1m";
const FAINT: &str = "\x1b[0;2m";
const RED: &str = "\x1b[0;31m";
const GREEN: &str = "\x1b[0;32m";
const YELLOW: &str = "\x1b[0;33m";

/// The meters show the top 60 dB in this many cells.
const FLOOR: f32 = -60.0;
const CELLS: usize = 50;
const YELLOW_ABOVE: f32 = -12.0;
const RED_ABOVE: f32 = -3.0;
/// The panel's width without its margin: a meter with its label and number.
const WIDTH: usize = 3 + CELLS + 10;

const TICK: Duration = Duration::from_millis(100);
const TICKS_PER_SECOND: u32 = 10;
/// How far a meter falls back in one tick, in dB, and for how many ticks it
/// keeps marking a peak.
const FALL: f32 = 2.0;
const HOLD_TICKS: u32 = 15;
/// Android counts as sending nothing after this long without audio.
const STALLED: Duration = Duration::from_millis(1500);
const PLAIN_INTERVAL: Duration = Duration::from_secs(60);

/// How many lines of the terminal the panel occupies right now. Whoever
/// writes to the terminal holds this lock.
static PANEL: Mutex<usize> = Mutex::new(0);

/// Whether stderr is a terminal that understands escape sequences.
fn fancy() -> bool {
    static FANCY: OnceLock<bool> = OnceLock::new();
    *FANCY.get_or_init(|| io::stderr().is_terminal() && escapes_work())
}

#[cfg(not(windows))]
fn escapes_work() -> bool {
    std::env::var("TERM").is_ok_and(|term| term != "dumb")
}

/// A Windows console only understands escape sequences once it is told to.
#[cfg(windows)]
fn escapes_work() -> bool {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;

    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 4;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetConsoleMode(console: *mut c_void, mode: *mut u32) -> i32;
        fn SetConsoleMode(console: *mut c_void, mode: u32) -> i32;
    }

    let console = io::stderr().as_raw_handle();
    let mut mode = 0;
    // SAFETY: the handle is stderr's, which stays open, and `mode` is a
    // valid place for the answer.
    unsafe {
        GetConsoleMode(console, &mut mode) != 0
            && SetConsoleMode(console, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0
    }
}

/// Writes to the terminal, without the colours if the user wants none.
fn emit(text: &str) {
    static COLOURS: OnceLock<bool> = OnceLock::new();
    let colours =
        *COLOURS.get_or_init(|| std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()));
    let mut terminal = io::stderr().lock();
    let _ = if colours {
        terminal.write_all(text.as_bytes())
    } else {
        terminal.write_all(without_colours(text).as_bytes())
    };
    let _ = terminal.flush();
}

/// Removes the escape sequences that set colours and leaves the others.
fn without_colours(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("\x1b[") {
        let body = &rest[start + 2..];
        let len = body
            .find(|c: char| c.is_ascii_alphabetic())
            .map_or(body.len(), |end| end + 1);
        out.push_str(&rest[..start]);
        if !body[..len].ends_with('m') {
            out.push_str(&rest[start..start + 2 + len]);
        }
        rest = &body[len..];
    }
    out.push_str(rest);
    out
}

/// Prints a full line. The panel, if there is one, makes room and comes back
/// below the line.
pub fn note(message: &str) {
    line("", message);
}

pub fn warn(message: &str) {
    line(YELLOW, message);
}

/// A line that matters less than the others.
pub fn detail(message: &str) {
    line(FAINT, message);
}

pub fn success(message: &str) {
    line(GREEN, message);
}

pub fn error(message: &str) {
    line(RED, message);
}

fn line(style: &str, message: &str) {
    let mut panel = PANEL.lock().unwrap();
    let mut out = String::new();
    erase(&mut panel, &mut out);
    if fancy() && !style.is_empty() {
        let _ = writeln!(out, "{style}{message}{RESET}");
    } else {
        let _ = writeln!(out, "{message}");
    }
    emit(&out);
}

/// Takes the panel off the terminal, leaving the cursor where it began.
fn erase(panel: &mut usize, out: &mut String) {
    if *panel > 0 {
        let _ = write!(out, "\x1b[{}A\r\x1b[J", *panel);
        *panel = 0;
    }
}

/// A sample's level in dB below full scale; silence is minus infinity.
fn decibels(peak: u16) -> f32 {
    20.0 * (peak as f32 / 32768.0).log10()
}

/// A level as text of a fixed width.
pub fn level(peak: u16) -> String {
    if peak == 0 {
        "   -∞ dB".into()
    } else {
        // Adding zero turns a rounded "-0.0" into "0.0".
        format!("{:>5.1} dB", (decibels(peak) * 10.0).round() / 10.0 + 0.0)
    }
}

/// What the recording loop tells the painter.
struct Levels {
    frames: u64,
    /// The highest sample of each channel since the painter last looked.
    recent: [u16; 2],
    /// The highest sample of the recording.
    highest: u16,
    gaps: u32,
    last_audio: Instant,
}

pub struct Screen {
    levels: Arc<Mutex<Levels>>,
    painter: Option<(Arc<AtomicBool>, JoinHandle<()>)>,
    // For the plain line, when there is no painter.
    last_line: Instant,
    since_line: u16,
}

impl Screen {
    /// Starts showing the recording of `file`.
    pub fn start(file: String) -> Screen {
        let levels = Arc::new(Mutex::new(Levels {
            frames: 0,
            recent: [0; 2],
            highest: 0,
            gaps: 0,
            last_audio: Instant::now(),
        }));
        let painter = fancy().then(|| {
            emit("\x1b[?25l");
            let stop = Arc::new(AtomicBool::new(false));
            let thread = {
                let (levels, stop) = (levels.clone(), stop.clone());
                std::thread::spawn(move || paint(&file, &levels, &stop))
            };
            (stop, thread)
        });
        Screen {
            levels,
            painter,
            last_line: Instant::now(),
            since_line: 0,
        }
    }

    /// Takes in audio that was just written; `frames` is the recording's
    /// length with it.
    pub fn audio(&mut self, pcm: &[u8], frames: u64) {
        let mut peaks = [0u16; 2];
        for frame in pcm.as_chunks::<4>().0 {
            let sample = |at| i16::from_le_bytes([frame[at], frame[at + 1]]).unsigned_abs();
            peaks[0] = peaks[0].max(sample(0));
            peaks[1] = peaks[1].max(sample(2));
        }
        let peak = peaks[0].max(peaks[1]);
        {
            let mut levels = self.levels.lock().unwrap();
            levels.frames = frames;
            levels.recent[0] = levels.recent[0].max(peaks[0]);
            levels.recent[1] = levels.recent[1].max(peaks[1]);
            levels.highest = levels.highest.max(peak);
            levels.last_audio = Instant::now();
        }
        if self.painter.is_none() {
            self.since_line = self.since_line.max(peak);
            if self.last_line.elapsed() >= PLAIN_INTERVAL {
                note(&format!(
                    "  {}  level {}",
                    clock(frames),
                    level(self.since_line).trim_start()
                ));
                self.since_line = 0;
                self.last_line = Instant::now();
            }
        }
    }

    /// Counts a stretch for which Android delivered no audio.
    pub fn gap(&mut self) {
        self.levels.lock().unwrap().gaps += 1;
    }

    /// Takes the panel off the terminal and returns the highest sample of
    /// the recording.
    pub fn close(mut self) -> u16 {
        self.remove();
        self.levels.lock().unwrap().highest
    }

    fn remove(&mut self) {
        let Some((stop, thread)) = self.painter.take() else {
            return;
        };
        stop.store(true, Ordering::Relaxed);
        let _ = thread.join();
        let mut panel = PANEL.lock().unwrap();
        let mut out = String::new();
        erase(&mut panel, &mut out);
        out.push_str("\x1b[?25h");
        emit(&out);
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        self.remove();
    }
}

/// One channel's meter: it jumps up with the audio, falls back slowly and
/// marks the last peak for a moment.
#[derive(Clone, Copy)]
struct Meter {
    level: f32,
    hold: f32,
    held: u32,
}

impl Meter {
    fn update(&mut self, peak: u16) {
        let now = decibels(peak);
        self.level = now.max(self.level - FALL);
        if now >= self.hold {
            self.hold = now;
            self.held = 0;
        } else if self.held < HOLD_TICKS {
            self.held += 1;
        } else {
            self.hold = self.level;
        }
    }
}

/// Redraws the panel until told to stop.
fn paint(file: &str, levels: &Mutex<Levels>, stop: &AtomicBool) {
    let silent = Meter {
        level: f32::NEG_INFINITY,
        hold: f32::NEG_INFINITY,
        held: 0,
    };
    let mut meters = [silent; 2];
    // The highest sample of each of the last seconds, the latest last.
    let mut history = VecDeque::with_capacity(CELLS);
    let mut this_second = 0u16;
    let mut tick = 0u32;
    while !stop.load(Ordering::Relaxed) {
        let (frames, recent, highest, gaps, quiet) = {
            let mut levels = levels.lock().unwrap();
            (
                levels.frames,
                std::mem::take(&mut levels.recent),
                levels.highest,
                levels.gaps,
                levels.last_audio.elapsed(),
            )
        };
        meters[0].update(recent[0]);
        meters[1].update(recent[1]);
        this_second = this_second.max(recent[0]).max(recent[1]);
        tick += 1;
        if tick.is_multiple_of(TICKS_PER_SECOND) {
            if history.len() == CELLS {
                history.pop_front();
            }
            history.push_back(std::mem::take(&mut this_second));
        }

        let stalled = quiet >= STALLED;
        let lines = [
            String::new(),
            headline(
                file,
                frames,
                stalled,
                (tick / (TICKS_PER_SECOND / 2)).is_multiple_of(2),
            ),
            String::new(),
            meter_line('L', &meters[0]),
            meter_line('R', &meters[1]),
            format!("     {FAINT}{}", scale()),
            String::new(),
            history_line(&history),
            footer(highest, gaps, stalled.then_some(quiet)),
        ];
        draw(&lines);
        std::thread::sleep(TICK);
    }
}

fn draw(lines: &[String]) {
    let mut panel = PANEL.lock().unwrap();
    // Without line wrapping, so that a narrow terminal cuts the panel off
    // instead of breaking it up.
    let mut out = String::from("\x1b[?7l");
    if *panel > 0 {
        let _ = write!(out, "\x1b[{}A", *panel);
    }
    out.push('\r');
    for line in lines {
        let _ = writeln!(out, "\x1b[2K{line}{RESET}");
    }
    out.push_str("\x1b[?7h");
    *panel = lines.len();
    emit(&out);
}

/// `left` and `right` at the two ends of a line of the panel's width. The
/// lengths are those of the visible text.
fn spread(left: &str, left_len: usize, right: &str, right_len: usize) -> String {
    let gap = WIDTH.saturating_sub(left_len + right_len).max(1);
    format!("  {left}{RESET}{:gap$}{right}", "")
}

fn headline(file: &str, frames: u64, stalled: bool, lit: bool) -> String {
    let time = clock(frames);
    let left = match (stalled, lit) {
        (true, _) => format!("{YELLOW}○ REC{RESET}  {BOLD}{time}"),
        (false, true) => format!("{RED}● REC{RESET}  {BOLD}{time}"),
        (false, false) => format!("{FAINT}●{RED} REC{RESET}  {BOLD}{time}"),
    };
    let left_len = 7 + time.len();
    let size = size(frames);
    let size_len = 3 + size.chars().count();

    let room = WIDTH.saturating_sub(left_len + 2 + size_len);
    let mut name: String = file.chars().take(room).collect();
    if name.len() < file.len() {
        name.pop();
        name.push('…');
    }
    let right_len = name.chars().count() + size_len;
    let right = format!("{name}{FAINT} · {size}");
    spread(&left, left_len, &right, right_len)
}

/// Where a level is on a meter, in cells from its left end.
fn cells(db: f32) -> f32 {
    ((db - FLOOR) / -FLOOR * CELLS as f32).clamp(0.0, CELLS as f32)
}

fn colour(db: f32) -> &'static str {
    if db > RED_ABOVE {
        RED
    } else if db > YELLOW_ABOVE {
        YELLOW
    } else {
        GREEN
    }
}

fn meter_line(channel: char, meter: &Meter) -> String {
    const PARTS: [char; 9] = [' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'];
    let mut out = format!("  {FAINT}{channel}{RESET}  ");
    let eighths = (cells(meter.level) * 8.0).round() as usize;
    // The peak is marked in the cell it falls into; 0 is no mark.
    let mark = cells(meter.hold).ceil() as usize;
    let mut current = "";
    for cell in 0..CELLS {
        let filled = eighths.saturating_sub(cell * 8).min(8);
        let marked = cell + 1 == mark;
        let style = if filled > 0 || marked {
            // A cell has the colour of the level at its right end.
            colour(FLOOR + (cell + 1) as f32 * -FLOOR / CELLS as f32)
        } else {
            FAINT
        };
        if style != current {
            out.push_str(style);
            current = style;
        }
        out.push(match filled {
            0 if marked => '│',
            0 => '░',
            _ => PARTS[filled],
        });
    }
    let peak = if meter.hold == f32::NEG_INFINITY {
        level(0)
    } else {
        format!("{:>5.1} dB", (meter.hold * 10.0).round() / 10.0 + 0.0)
    };
    let _ = write!(out, "{RESET}  {peak}");
    out
}

/// The numbers under the meters.
fn scale() -> String {
    let mut line = vec![' '; CELLS + 1];
    for db in (FLOOR as i32..=0).step_by(12) {
        let label = db.to_string();
        let at = cells(db as f32) as usize;
        let start = at
            .saturating_sub(label.len() / 2)
            .min(line.len() - label.len());
        for (cell, digit) in line[start..].iter_mut().zip(label.chars()) {
            *cell = digit;
        }
    }
    line.into_iter().collect()
}

fn history_line(history: &VecDeque<u16>) -> String {
    const HEIGHTS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let mut out = format!("     {:1$}", "", CELLS - history.len());
    let mut current = "";
    for &peak in history {
        let db = decibels(peak);
        let height = (cells(db) / CELLS as f32 * 8.0).ceil() as usize;
        let style = if height == 0 { FAINT } else { colour(db) };
        if style != current {
            out.push_str(style);
            current = style;
        }
        out.push(HEIGHTS[height.saturating_sub(1)]);
    }
    let _ = write!(out, "{FAINT}  last {CELLS} s");
    out
}

fn footer(highest: u16, gaps: u32, quiet: Option<Duration>) -> String {
    let left = if let Some(quiet) = quiet {
        format!("Android sent no audio for {} s", quiet.as_secs())
    } else {
        let peak = if highest == 0 {
            "no sound yet".to_string()
        } else {
            format!("peak {}", level(highest).trim_start())
        };
        match gaps {
            0 => format!("{peak} · 48 kHz, 16 bit, stereo"),
            1 => format!("{peak} · 1 interruption"),
            _ => format!("{peak} · {gaps} interruptions"),
        }
    };
    let style = if quiet.is_some() || gaps > 0 {
        YELLOW
    } else {
        FAINT
    };
    let right = "Ctrl+C to stop";
    spread(
        &format!("{style}{left}"),
        left.chars().count(),
        &format!("{FAINT}{right}"),
        right.len(),
    )
}
