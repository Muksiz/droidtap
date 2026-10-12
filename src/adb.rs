//! A minimal client for the adb server (the process `adb start-server`
//! leaves running, normally on 127.0.0.1:5037). Talking to it directly means
//! droidtap needs no `adb` binary of its own, and cannot trip over the
//! version check that makes mismatched adb clients restart the server.

use std::io::{self, Read, Write};
use std::net::TcpStream;

const SYNC_CHUNK: usize = 64 * 1024;

pub struct Adb {
    pub addr: String,
    pub serial: Option<String>,
}

impl Adb {
    /// Opens a service on the device, e.g. `shell:ls` or `localabstract:name`.
    /// The returned stream carries that service's data.
    pub fn open(&self, service: &str) -> io::Result<TcpStream> {
        let mut stream = TcpStream::connect(&self.addr).map_err(|e| {
            io::Error::new(e.kind(), format!("no adb server at {}: {e}", self.addr))
        })?;
        stream.set_nodelay(true)?;
        match &self.serial {
            Some(serial) => request(&mut stream, &format!("host:transport:{serial}"))?,
            None => request(&mut stream, "host:transport-any")?,
        }
        request(&mut stream, service)?;
        Ok(stream)
    }

    /// Runs a shell command and returns everything it printed.
    pub fn shell(&self, command: &str) -> io::Result<String> {
        let mut output = String::new();
        self.open(&format!("shell:{command}"))?
            .read_to_string(&mut output)?;
        Ok(output)
    }

    /// Writes `data` to the file `remote` on the device.
    pub fn push(&self, data: &[u8], remote: &str, mode: u32) -> io::Result<()> {
        let mut stream = self.open("sync:")?;
        let target = format!("{remote},{mode}");
        sync_packet(&mut stream, b"SEND", target.as_bytes())?;
        for chunk in data.chunks(SYNC_CHUNK) {
            sync_packet(&mut stream, b"DATA", chunk)?;
        }
        stream.write_all(b"DONE")?;
        stream.write_all(&0u32.to_le_bytes())?; // modification time

        let mut reply = [0u8; 8];
        stream.read_exact(&mut reply)?;
        if &reply[..4] == b"OKAY" {
            return Ok(());
        }
        let len = u32::from_le_bytes(reply[4..].try_into().unwrap()) as usize;
        let mut message = vec![0u8; len.min(4096)];
        stream.read_exact(&mut message)?;
        Err(io::Error::other(format!(
            "could not write {remote}: {}",
            String::from_utf8_lossy(&message)
        )))
    }
}

/// Sends one request to the adb server and checks its OKAY/FAIL answer.
fn request(stream: &mut TcpStream, payload: &str) -> io::Result<()> {
    stream.write_all(format!("{:04x}{payload}", payload.len()).as_bytes())?;
    let mut status = [0u8; 4];
    stream.read_exact(&mut status)?;
    if &status == b"OKAY" {
        return Ok(());
    }
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let len = std::str::from_utf8(&len)
        .ok()
        .and_then(|hex| usize::from_str_radix(hex, 16).ok())
        .unwrap_or(0);
    let mut message = vec![0u8; len];
    stream.read_exact(&mut message)?;
    Err(io::Error::other(
        String::from_utf8_lossy(&message).into_owned(),
    ))
}

fn sync_packet(stream: &mut TcpStream, id: &[u8; 4], data: &[u8]) -> io::Result<()> {
    stream.write_all(id)?;
    stream.write_all(&(data.len() as u32).to_le_bytes())?;
    stream.write_all(data)
}
