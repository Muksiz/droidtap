# droidtap

> **Status:** early. Tested on Linux (Podman) with the bundled emulator: test
> tones were recorded bit for bit, over ten minutes of ordinary computer use
> and with every processor core busy. Real phones and Windows are untested.

Records what an Android device plays into a WAV file (48 kHz, 16 bit, stereo)
without touching the computer's sound.

The audio is captured inside Android by [scrcpy](https://github.com/Genymobile/scrcpy)'s
server program and reaches `droidtap` through adb, as a network stream:

```
Android mixer ──► scrcpy-server (on the device) ──► adb ──► droidtap ──► recordings/name.wav
```

No sound device of the computer is ever opened. The computer's own audio
cannot end up in a recording, and a recording cannot be heard on the computer
or change its volume or devices. You therefore cannot listen live: watch the
level `droidtap` prints and check the file afterwards.

## With the bundled emulator (containers)

Needs Docker or Podman with compose, and `/dev/kvm`.

```sh
./droidtap.sh start            # Android in a browser desktop: http://localhost:6080
./droidtap.sh record my-book   # records until Ctrl+C -> recordings/my-book.wav
./droidtap.sh stop             # Android, its apps and logins are kept
```

Without the script:

```sh
docker compose up -d --build
docker compose --profile record run --rm recorder my-book
docker compose down
```

Two containers are involved: `emulator` (the Android emulator, shown through
noVNC; it has no sound device) and `recorder` (`droidtap`, started once per
recording). The recorder reaches the emulator's adb server over the compose
network; only port 6080 is published, on `127.0.0.1`, without a password.

Settings (`SCREEN`, `EMULATOR_RAM_MB`, `EMULATOR_CORES`, `EMULATOR_DATA_SIZE`)
can be overridden in a `.env` file next to `compose.yaml`.

## With a real phone, or without containers

`droidtap` is a single program for Linux and Windows. It needs a running adb
server (`adb start-server`) with a device attached, Android 11 or newer, and
the `scrcpy-server` file of the matching version (5.0.1) next to the program
or given with `--server`.

```sh
cargo build --release
./target/release/droidtap --server path/to/scrcpy-server my-book
```

See `droidtap --help` for the options.

## Notes

- While recording with the default `--source output`, the device itself is
  silent: Android redirects its output into the capture.
- With `--source output`, Android applies its media volume to the captured
  audio. `droidtap` therefore sets that volume to the maximum when a recording
  starts, which makes the capture an exact copy of what the apps play. Android
  keeps a separate volume for each output, so the volume of the device's
  speaker or headphones is not changed. Do not turn the volume down on the
  device while recording.
- `droidtap` prints a note whenever Android delivered no audio for more than
  50 ms. Pauses in playback cause these too.
- The WAV header is rewritten every few seconds, so a recording survives a
  crash. Files over 4 GB (about 6 hours) are written as RF64.
- Only record material you have the right to copy.
