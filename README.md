# droidtap

> **Status:** early. Tested on Linux (Podman) with the bundled emulator: test
> tones were recorded bit for bit, over ten minutes of ordinary computer use
> and with every processor core busy. Real phones and Windows are untested.

Records what an Android device plays into a WAV file (48 kHz, 16 bit, stereo
or mono) without touching the computer's sound.

The audio is captured inside Android by [scrcpy](https://github.com/Genymobile/scrcpy)'s
server program and reaches `droidtap` through adb, as a network stream:

```
Android mixer ──► scrcpy-server (on the device) ──► adb ──► droidtap ──► recordings/name.wav
```

`droidtap` never opens a sound device of the computer. The computer's own
audio cannot end up in a recording, and recording cannot change the computer's
volume or devices. Watch the level meters `droidtap` shows, or listen to the
file while it is being written (see `listen` below).

## With the bundled emulator (containers)

Needs Docker or Podman with compose, and `/dev/kvm`.

```sh
./droidtap.sh start            # opens Android in a browser desktop (http://localhost:6080), starting it if needed
./droidtap.sh record my-book   # records until Ctrl+C -> recordings/my-book.wav
./droidtap.sh record --mono my-book   # the same with one channel, at half the size
./droidtap.sh listen           # in a second terminal: plays the recording being made
./droidtap.sh recordings       # opens the recordings folder
./droidtap.sh stop             # Android, its apps and logins are kept
./droidtap.sh update           # git pull, rebuild the containers
```

`./droidtap.sh` without a command shows a menu with the same choices, plus
`status`; before a recording it asks for the name and for stereo or mono. On
Windows, `droidtap.bat` does the same; double-click it for the menu. It starts
Docker Desktop first if that is not running.

`listen` needs `ffplay`, which comes with [FFmpeg](https://ffmpeg.org) (on
Windows: `winget install Gyan.FFmpeg`). Instead of installing it you can put
the `ffplay` program (`ffplay.exe` on Windows) next to the script. It plays the newest recording, or the
one named, from a second before its end and follows the file as it grows. It
only reads the file, so the recording is not affected; what you hear is about
a second behind Android.

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

Settings (`SCREEN`, `EMULATOR_SCALE`, `EMULATOR_RAM_MB`, `EMULATOR_CORES`,
`EMULATOR_DATA_SIZE`) can be overridden in a `.env` file next to
`compose.yaml`. The emulator's window is made as large as the desktop has
room for; `EMULATOR_SCALE` is its size in percent of the Android screen
instead.

### On Windows 11 with Docker Desktop

Needs:

- Windows 11 on an x86-64 (Intel/AMD) machine with virtualization enabled in
  the BIOS/UEFI. Windows on ARM is not supported.
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) using the
  **WSL 2** backend (Settings → General → "Use the WSL 2 based engine").
- [Git for Windows](https://git-scm.com/download/win).
- About 15 GB of free disk space and 8 GB of RAM available to WSL.

```powershell
git clone https://github.com/Muksiz/droidtap.git
cd droidtap
.\droidtap.bat start
```

The first start downloads the Android system image and takes a while; the
resulting image is several GB. Later starts take seconds. For a desktop icon,
right-click `droidtap.bat` → Show more options → Send to → Desktop (create
shortcut).

The emulator needs `/dev/kvm`, which WSL 2 provides through nested
virtualization. Recent WSL kernels (6.x) ship the KVM driver as a module that
is not loaded automatically and is forgotten on every restart of WSL, Docker
Desktop or Windows. `droidtap` therefore loads it for you: starting Android
first runs a small helper container (`kvm`) that does so.

If the start ends with `service "kvm" didn't complete successfully` or with
`error gathering device information while adding custom device "/dev/kvm"`,
first try loading the driver by hand:

```powershell
wsl -d docker-desktop sh -c "modprobe kvm_amd; ls -l /dev/kvm"
```

Use `kvm_intel` instead of `kvm_amd` on an Intel CPU. If this prints a line
starting with `crw`, start Android again.

If `modprobe` fails, nested virtualization is not enabled yet:

1. Open the WSL settings file:

   ```powershell
   notepad $env:USERPROFILE\.wslconfig
   ```

   and make it contain (answer "Yes" if Notepad asks to create the file):

   ```ini
   [wsl2]
   nestedVirtualization=true
   ```

2. Update and restart WSL. Run these as two separate commands:

   ```powershell
   wsl --update
   ```

   ```powershell
   wsl --shutdown
   ```

3. Quit Docker Desktop completely (tray icon → Quit Docker Desktop) and start
   Android again; `droidtap.bat` starts Docker Desktop for you.

Still failing? See [Troubleshooting](#troubleshooting).

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

## Troubleshooting

**`/dev/kvm` is still missing on Windows**
Run these one at a time and compare:

```powershell
wsl --version
```

The WSL version should be 2.x and the kernel 5.15 or newer. If the command is
not recognised or reports an old version, install the current WSL from the
Microsoft Store or with `wsl --update`.

```powershell
wsl -l -v
```

`docker-desktop` must be listed with VERSION 2. If it is missing, Docker
Desktop is using Hyper-V instead: enable Settings → General → "Use the WSL 2
based engine".

```powershell
wsl -d docker-desktop ls -l /dev/kvm
```

If this prints `No such file or directory`, the WSL virtual machine itself has
no KVM. Find out why with:

```powershell
wsl -d docker-desktop sh -c "uname -r; grep -cE 'vmx|svm' /proc/cpuinfo; dmesg | grep -i kvm"
```

```powershell
Get-Content $env:USERPROFILE\.wslconfig
```

```powershell
(Get-CimInstance Win32_Processor).Name
```

The first command prints the kernel version and then a count. A count of `0`
means nested virtualization is not reaching WSL: `.wslconfig` is not being
picked up, or the CPU, firmware or Windows setup does not offer it. A count
above 0 without `/dev/kvm` points at an outdated WSL kernel (`wsl --update`).

Then check that:

- virtualization (Intel VT-x / AMD-V, sometimes "SVM") is enabled in the
  BIOS/UEFI — Task Manager → Performance → CPU shows "Virtualization: Enabled";
- the "Virtual Machine Platform" Windows feature is on (`optionalfeatures.exe`);
- `.wslconfig` is saved as `%UserProfile%\.wslconfig`, not `.wslconfig.txt`;
- Windows is not itself running inside a virtual machine (nested
  virtualization is then usually unavailable);
- on AMD CPUs, the CPU is a Ryzen/EPYC.

**Seeing what is going on**

```powershell
docker compose logs -f
docker exec droidtap-emulator adb devices
```

## Notes

- While recording with the default `--source output`, the device itself is
  silent: Android redirects its output into the capture.
- With `--source output`, Android applies its media volume to the captured
  audio. `droidtap` therefore sets that volume to the maximum when a recording
  starts, which makes the capture an exact copy of what the apps play. Android
  keeps a separate volume for each output, so the volume of the device's
  speaker or headphones is not changed. Do not turn the volume down on the
  device while recording.
- Android always delivers stereo. With `--mono`, `droidtap` writes the mean
  of the left and the right channel.
- `droidtap` prints a note whenever Android delivered no audio for more than
  50 ms, and whenever the audio was completely silent for more than 20 ms
  between two sounds. Pauses in playback cause these too.
- The WAV header is rewritten every few seconds, so a recording survives a
  crash. Files over 4 GB (about 6 hours) are written as RF64.
- Only record material you have the right to copy.
