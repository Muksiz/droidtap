//! WAV writer for recordings of unknown, possibly very long, duration.
//!
//! The header is rewritten every few seconds, so a recording stays playable
//! even if the program is killed. A plain WAV file cannot exceed 4 GB (about
//! 6 hours here); past that the header is switched to RF64, the standard
//! extension for long files, using space reserved for it up front.

use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Seek, SeekFrom, Write};
use std::path::Path;

pub const RATE: u32 = 48000;
pub const BYTES_PER_SAMPLE: u16 = 2;

const HEADER_LEN: u64 = 80;

pub struct Wav {
    out: BufWriter<File>,
    channels: u16,
    data_len: u64,
}

impl Wav {
    /// Creates the file; fails if it already exists.
    pub fn create(path: &Path, channels: u16) -> io::Result<Wav> {
        let file = OpenOptions::new().write(true).create_new(true).open(path)?;
        let mut out = BufWriter::with_capacity(1 << 16, file);
        out.write_all(&header(channels, 0))?;
        Ok(Wav {
            out,
            channels,
            data_len: 0,
        })
    }

    pub fn write(&mut self, pcm: &[u8]) -> io::Result<()> {
        self.out.write_all(pcm)?;
        self.data_len += pcm.len() as u64;
        Ok(())
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    pub fn frames(&self) -> u64 {
        self.data_len / frame(self.channels)
    }

    /// Brings the file on disk up to date, header included.
    pub fn sync(&mut self) -> io::Result<()> {
        self.out.flush()?;
        let file = self.out.get_mut();
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&header(self.channels, self.data_len))?;
        file.seek(SeekFrom::End(0))?;
        Ok(())
    }
}

/// The bytes of one frame: a sample of each channel.
pub fn frame(channels: u16) -> u64 {
    (channels * BYTES_PER_SAMPLE) as u64
}

fn header(channels: u16, data_len: u64) -> [u8; HEADER_LEN as usize] {
    let riff_len = HEADER_LEN - 8 + data_len;
    let rf64 = riff_len > u32::MAX as u64;
    let block = channels * BYTES_PER_SAMPLE;

    let mut h = Vec::with_capacity(HEADER_LEN as usize);
    if rf64 {
        h.extend(b"RF64");
        h.extend(u32::MAX.to_le_bytes());
        h.extend(b"WAVEds64");
        h.extend(28u32.to_le_bytes());
        h.extend(riff_len.to_le_bytes());
        h.extend(data_len.to_le_bytes());
        h.extend((data_len / block as u64).to_le_bytes());
        h.extend(0u32.to_le_bytes());
    } else {
        h.extend(b"RIFF");
        h.extend((riff_len as u32).to_le_bytes());
        h.extend(b"WAVEJUNK"); // placeholder, becomes ds64 if the file outgrows 4 GB
        h.extend(28u32.to_le_bytes());
        h.extend([0u8; 28]);
    }
    h.extend(b"fmt ");
    h.extend(16u32.to_le_bytes());
    h.extend(1u16.to_le_bytes()); // PCM
    h.extend(channels.to_le_bytes());
    h.extend(RATE.to_le_bytes());
    h.extend((RATE * block as u32).to_le_bytes());
    h.extend(block.to_le_bytes());
    h.extend((BYTES_PER_SAMPLE * 8).to_le_bytes());
    h.extend(b"data");
    h.extend(if rf64 { u32::MAX } else { data_len as u32 }.to_le_bytes());
    h.try_into().unwrap()
}
