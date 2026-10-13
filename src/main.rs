//! droidtap records what an Android device plays into a WAV file.
//!
//! The audio is captured inside Android by scrcpy's server program and reaches
//! this process through adb, as a network stream. No sound device of the
//! computer is ever opened, so the computer's own audio cannot end up in the
//! recording and the recording cannot be heard on, or disturb, the computer.

mod adb;
mod screen;
mod wav;

use std::io::{self, BufRead, BufReader, Read};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use adb::Adb;
use screen::{Screen, note, warn};
use wav::Wav;

/// Must match the scrcpy-server file in use; the server refuses other clients.
const DEFAULT_SERVER_VERSION: &str = "5.0.1";
const DEVICE_SERVER_PATH: &str = "/data/local/tmp/droidtap-server.jar";

/// Sets Android's media volume to its maximum; built from android/Volume.java.
const VOLUME_HELPER: &[u8] = include_bytes!("../android/volume.dex");
const DEVICE_VOLUME_HELPER_PATH: &str = "/data/local/tmp/droidtap-volume.dex";

// scrcpy's stream format: a 4-byte codec id, then packets made of a 12-byte
// header (flags and timestamp, payload length; big-endian) and the payload.
const CODEC_RAW: u32 = 0x0072_6177; // "raw": 48 kHz, 16 bit, stereo PCM
const STEREO: u16 = 2;
const FLAG_CONFIG: u64 = 1 << 62;
const PTS_MASK: u64 = (1 << 61) - 1;
const MAX_PACKET: usize = 1 << 20;

/// Report when Android's clock ran this far ahead of the audio it delivered.
const GAP_US: u64 = 50_000;
const SYNC_INTERVAL: Duration = Duration::from_secs(5);

const HELP: &str = "\
Records an Android device's audio to a WAV file (48 kHz, 16 bit, stereo or
mono).
Stop with Ctrl+C.

Usage: droidtap [options] [name]

  name                   file name without .wav (default: droid-<date>-<time>)

Options:
  -o, --out DIR          folder for recordings      [DROIDTAP_OUT, default: recordings]
  -s, --serial SERIAL    device to use, if several  [ANDROID_SERIAL]
      --adb HOST:PORT    adb server                 [DROIDTAP_ADB, default: 127.0.0.1:5037]
      --server FILE      scrcpy-server file         [SCRCPY_SERVER_PATH, default: next to droidtap]
      --source SOURCE    output:   everything Android plays; the device itself
                                   goes silent while recording (default)
                         playback: the device keeps playing too (Android 13+);
                                   apps may opt out of being captured
      --mono             record one channel, the mean of left and right,
                         instead of stereo
      --wait SECONDS     how long to wait for the device (default: 300)
  -h, --help             show this help
";

struct Options {
    name: Option<String>,
    out: PathBuf,
    adb: String,
    serial: Option<String>,
    server: PathBuf,
    server_version: String,
    source: String,
    mono: bool,
    wait: u64,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn parse_args() -> Result<Options, String> {
    let default_server = || {
        let exe = std::env::current_exe().unwrap_or_default();
        exe.with_file_name("scrcpy-server")
    };
    let mut opts = Options {
        name: None,
        out: env("DROIDTAP_OUT").map_or_else(|| "recordings".into(), PathBuf::from),
        adb: env("DROIDTAP_ADB").unwrap_or_else(|| "127.0.0.1:5037".into()),
        serial: env("ANDROID_SERIAL"),
        server: env("SCRCPY_SERVER_PATH").map_or_else(default_server, PathBuf::from),
        server_version: env("SCRCPY_SERVER_VERSION")
            .unwrap_or_else(|| DEFAULT_SERVER_VERSION.into()),
        source: "output".into(),
        mono: false,
        wait: 300,
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{HELP}");
                std::process::exit(0);
            }
            "-o" | "--out" => opts.out = value()?.into(),
            "-s" | "--serial" => opts.serial = Some(value()?),
            "--adb" => opts.adb = value()?,
            "--server" => opts.server = value()?.into(),
            "--source" => opts.source = value()?,
            "--mono" => opts.mono = true,
            "--wait" => {
                opts.wait = value()?
                    .parse()
                    .map_err(|_| "--wait needs a number of seconds")?
            }
            _ if arg.starts_with('-') => return Err(format!("unknown option {arg} (see --help)")),
            _ if opts.name.is_none() => opts.name = Some(arg),
            _ => return Err(format!("unexpected argument {arg} (see --help)")),
        }
    }
    if !matches!(opts.source.as_str(), "output" | "playback") {
        return Err("--source must be output or playback".into());
    }
    if let Some(name) = &opts.name
        && name.contains(['/', '\\'])
    {
        return Err("the name must not contain a folder; use --out for that".into());
    }
    Ok(opts)
}

fn main() -> ExitCode {
    match parse_args().and_then(|opts| run(opts).map_err(|e| e.to_string())) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            screen::error(&format!("droidtap: {message}"));
            ExitCode::FAILURE
        }
    }
}

fn run(opts: Options) -> io::Result<()> {
    let stop = Arc::new(AtomicBool::new(false));
    {
        let stop = stop.clone();
        ctrlc::set_handler(move || stop.store(true, Ordering::Relaxed))
            .map_err(io::Error::other)?;
    }

    let server = std::fs::read(&opts.server).map_err(|e| {
        io::Error::new(
            e.kind(),
            format!(
                "cannot read the scrcpy-server file {}: {e}",
                opts.server.display()
            ),
        )
    })?;
    let adb = Adb {
        addr: opts.adb.clone(),
        serial: opts.serial.clone(),
    };
    if !wait_for_device(&adb, opts.wait, &stop)? {
        return Ok(());
    }

    std::fs::create_dir_all(&opts.out)?;
    let name = opts.name.clone().unwrap_or_else(default_name);
    let path = opts.out.join(format!("{name}.wav"));
    let mut wav = Wav::create(&path, if opts.mono { 1 } else { STEREO })
        .map_err(|e| io::Error::new(e.kind(), format!("cannot create {}: {e}", path.display())))?;

    adb.push(&server, DEVICE_SERVER_PATH, 0o100644)?;
    let scid = session_id();
    let mut command = format!(
        "CLASSPATH={DEVICE_SERVER_PATH} app_process / com.genymobile.scrcpy.Server {} \
         scid={scid:08x} log_level=info video=false control=false audio=true \
         audio_codec=raw audio_source={} tunnel_forward=true cleanup=false power_on=false \
         send_device_meta=false send_dummy_byte=false",
        opts.server_version, opts.source
    );
    if opts.source == "playback" {
        command.push_str(" audio_dup=true");
    }
    let server_gone = Arc::new(AtomicBool::new(false));
    {
        let log = BufReader::new(adb.open(&format!("shell:{command}"))?);
        let server_gone = server_gone.clone();
        std::thread::spawn(move || {
            for line in log.lines().map_while(Result::ok) {
                screen::detail(&format!("[android] {line}"));
            }
            server_gone.store(true, Ordering::Relaxed);
        });
    }

    let Some(mut audio) = connect_audio(&adb, scid, &server_gone, &stop)? else {
        return finish(wav, &path, 0, 0);
    };
    audio.set_read_timeout(Some(Duration::from_millis(250)))?;
    let mut codec = [0u8; 4];
    if !read_full(&mut audio, &mut codec, &stop)? {
        return finish(wav, &path, 0, 0);
    }
    match u32::from_be_bytes(codec) {
        CODEC_RAW => {}
        0 | 1 => {
            return Err(io::Error::other(
                "Android could not start the audio capture (see the [android] messages above)",
            ));
        }
        other => {
            return Err(io::Error::other(format!(
                "unexpected audio codec {other:#x}"
            )));
        }
    }

    let mut payload = Vec::new();
    if opts.source == "output" && !raise_volume(&adb, &mut audio, &mut payload, &stop)? {
        return finish(wav, &path, 0, 0);
    }

    note(&format!(
        "Recording to {} - press Ctrl+C to stop",
        path.display()
    ));
    let mut screen = Screen::start(format!("{name}.wav"), wav.channels());
    let mut last_sync = Instant::now();
    let mut expected_pts = None;
    let mut gaps = 0u32;
    while let Some(pts_and_flags) = read_packet(&mut audio, &mut payload, &stop)? {
        if pts_and_flags & FLAG_CONFIG != 0 {
            continue;
        }

        // Android stamps every packet with its capture time. A stamp well
        // past the end of the previous packet means Android delivered no
        // audio for that long: playback was paused, or audio was lost.
        let pts = pts_and_flags & PTS_MASK;
        if let Some(expected) = expected_pts
            && pts > expected + GAP_US
        {
            gaps += 1;
            screen.gap();
            note(&format!(
                "note: at {} Android delivered no audio for {} ms",
                clock(wav.frames()),
                (pts - expected) / 1000
            ));
        }
        let frames = payload.len() as u64 / wav::frame(STEREO);
        expected_pts = Some(pts + frames * 1_000_000 / wav::RATE as u64);

        if opts.mono {
            mix_down(&mut payload);
        }
        wav.write(&payload)?;
        screen.audio(&payload, wav.frames());
        if last_sync.elapsed() >= SYNC_INTERVAL {
            wav.sync()?;
            last_sync = Instant::now();
        }
    }

    let peak = screen.close();
    if !stop.load(Ordering::Relaxed) {
        note("Android closed the audio stream.");
    }
    finish(wav, &path, gaps, peak)
}

/// Waits until a device is connected and Android has finished starting.
/// Returns false if the user gave up first.
fn wait_for_device(adb: &Adb, timeout: u64, stop: &AtomicBool) -> io::Result<bool> {
    let started = Instant::now();
    let mut shown = String::new();
    loop {
        let problem = match adb.shell("getprop sys.boot_completed") {
            Ok(value) if value.trim() == "1" => return Ok(true),
            Ok(_) => "Android is still starting".to_string(),
            Err(e) => e.to_string(),
        };
        if stop.load(Ordering::Relaxed) {
            return Ok(false);
        }
        if started.elapsed() >= Duration::from_secs(timeout) {
            return Err(io::Error::other(format!(
                "no usable Android device: {problem}"
            )));
        }
        if problem != shown {
            note(&format!("Waiting for the Android device: {problem}"));
            shown = problem;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Connects to the socket the capture program opens once it is running.
fn connect_audio(
    adb: &Adb,
    scid: u32,
    server_gone: &AtomicBool,
    stop: &AtomicBool,
) -> io::Result<Option<TcpStream>> {
    let service = format!("localabstract:scrcpy_{scid:08x}");
    let started = Instant::now();
    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(None);
        }
        match adb.open(&service) {
            Ok(stream) => return Ok(Some(stream)),
            Err(_) if server_gone.load(Ordering::Relaxed) => {
                return Err(io::Error::other(
                    "the capture program on Android exited (see the [android] messages above)",
                ));
            }
            Err(e) if started.elapsed() >= Duration::from_secs(15) => {
                return Err(io::Error::other(format!(
                    "the capture program on Android did not start: {e}"
                )));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

/// With `--source output` Android applies its media volume to the captured
/// audio, so anything below the maximum costs level and resolution. Sets the
/// volume to the maximum. Android keeps a separate volume for each output, and
/// during the capture the output is the capture itself: the volume of the
/// speaker and of headphones stays as it was.
///
/// This takes a second; the audio captured meanwhile is dropped, so that the
/// level cannot jump inside the file. Returns false when the user asked to
/// stop or the stream ended.
fn raise_volume(
    adb: &Adb,
    audio: &mut TcpStream,
    payload: &mut Vec<u8>,
    stop: &AtomicBool,
) -> io::Result<bool> {
    let volume = std::thread::scope(|scope| {
        let helper = scope.spawn(|| {
            adb.push(VOLUME_HELPER, DEVICE_VOLUME_HELPER_PATH, 0o100644)?;
            adb.shell(&format!(
                "CLASSPATH={DEVICE_VOLUME_HELPER_PATH} app_process / Volume 2>&1"
            ))
        });
        while !helper.is_finished() {
            if read_packet(audio, payload, stop)?.is_none() {
                return Ok(None);
            }
        }
        helper.join().unwrap().map(Some)
    })?;
    let Some(output) = volume else {
        return Ok(false);
    };

    let numbers: Vec<u32> = output
        .split_whitespace()
        .map_while(|word| word.parse().ok())
        .collect();
    match numbers[..] {
        [before, after, max] if after == max => {
            if before != max {
                note(&format!(
                    "Android's media volume for captures was {before} of {max}: set it to {max}."
                ));
            }
        }
        [_, after, max] if max > 0 => warn(&format!(
            "warning: Android's media volume is {after} of {max} and could not be changed. \
             The recording will be quieter and noisier than the original; raise the \
             media volume on the device to its maximum while this is running."
        )),
        _ => warn(&format!(
            "warning: could not check Android's media volume ({}). If the recording is \
             quiet, raise the media volume on the device to its maximum while this is running.",
            output.lines().next().unwrap_or("no answer").trim()
        )),
    }
    Ok(true)
}

/// Reads one packet into `payload` and returns its flags and timestamp, or
/// None when the user asked to stop or the stream ended.
fn read_packet(
    stream: &mut TcpStream,
    payload: &mut Vec<u8>,
    stop: &AtomicBool,
) -> io::Result<Option<u64>> {
    let mut header = [0u8; 12];
    if !read_full(stream, &mut header, stop)? {
        return Ok(None);
    }
    let len = u32::from_be_bytes(header[8..].try_into().unwrap()) as usize;
    if len > MAX_PACKET {
        return Err(io::Error::other("the audio stream is corrupt"));
    }
    payload.resize(len, 0);
    if !read_full(stream, payload, stop)? {
        return Ok(None);
    }
    Ok(Some(u64::from_be_bytes(header[..8].try_into().unwrap())))
}

/// Fills `buf`, looking at the stop flag while waiting. Returns false when
/// the user asked to stop or the stream ended.
fn read_full(stream: &mut TcpStream, buf: &mut [u8], stop: &AtomicBool) -> io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        if stop.load(Ordering::Relaxed) {
            return Ok(false);
        }
        match stream.read(&mut buf[filled..]) {
            Ok(0) => return Ok(false),
            Ok(n) => filled += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

/// Makes stereo audio mono: every frame becomes the mean of its two samples.
fn mix_down(pcm: &mut Vec<u8>) {
    let mut len = 0;
    for at in (0..pcm.len() / 4 * 4).step_by(4) {
        let sample = |at| i16::from_le_bytes([pcm[at], pcm[at + 1]]) as i32;
        let mean = ((sample(at) + sample(at + 2)) >> 1) as i16;
        pcm[len..len + 2].copy_from_slice(&mean.to_le_bytes());
        len += 2;
    }
    pcm.truncate(len);
}

/// `peak` is the highest sample of the recording.
fn finish(mut wav: Wav, path: &std::path::Path, gaps: u32, peak: u16) -> io::Result<()> {
    wav.sync()?;
    let frames = wav.frames();
    let mut facts = clock(frames);
    if frames > 0 {
        facts.push_str(&format!(", {}, ", size(frames, wav.channels())));
        if peak == 0 {
            facts.push_str("silent");
        } else {
            facts.push_str(&format!("peak {}", screen::level(peak).trim_start()));
        }
    }
    screen::success(&format!("Saved {} ({facts})", path.display()));
    if gaps > 0 {
        note(&format!(
            "{gaps} interruption(s) were noted above. Pauses in playback are harmless; \
             anything else is worth a listen at that position."
        ));
    }
    Ok(())
}

fn clock(frames: u64) -> String {
    let seconds = frames / wav::RATE as u64;
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    )
}

/// The size of a recording of that many frames, without its header.
fn size(frames: u64, channels: u16) -> String {
    let megabytes = (frames * wav::frame(channels)) as f64 / 1e6;
    if megabytes < 1000.0 {
        format!("{megabytes:.1} MB")
    } else {
        format!("{:.2} GB", megabytes / 1000.0)
    }
}

fn since_epoch() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
}

/// A 31-bit number naming this session's socket on the device.
fn session_id() -> u32 {
    (since_epoch().subsec_nanos() ^ std::process::id().rotate_left(16)) & 0x7fff_ffff
}

/// `droid-YYYYMMDD-HHMMSS`, in UTC.
fn default_name() -> String {
    let now = since_epoch().as_secs();
    let (time, days) = (now % 86400, (now / 86400) as i64);
    // Days since 1970 to a calendar date (Howard Hinnant's civil_from_days).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "droid-{year:04}{month:02}{day:02}-{:02}{:02}{:02}",
        time / 3600,
        time / 60 % 60,
        time % 60
    )
}
