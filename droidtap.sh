#!/usr/bin/env bash
# Starts, stops, records with and updates droidtap on Linux or macOS; the
# counterpart of droidtap.bat. Without a command it shows a menu. Usage:
#   ./droidtap.sh [start | record [name] | listen [name] | recordings | stop | status | update]
set -u
cd "$(dirname "$0")"
self=./$(basename "$0")

URL=http://localhost:6080
CONTAINER=droidtap-emulator

# Everything is in functions, called from the last line: "update" replaces
# this file, and bash would otherwise go on reading the new one halfway.

# Colours and moving text are for a terminal; what is piped stays plain.
styles() {
    bold='' faint='' red='' green='' cyan='' off='' live=false
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        live=true
        if [ -z "${NO_COLOR:-}" ]; then
            bold=$'\033[1m' faint=$'\033[2m' red=$'\033[31m' green=$'\033[32m'
            cyan=$'\033[36m' off=$'\033[0m'
        fi
    fi
}

step() { echo "${cyan}▸${off} ${bold}$*${off}"; }
good() { echo "${green}✓${off} $*"; }
bad() { echo "${red}✗${off} $*" >&2; }

find_engine() {
    if docker compose version > /dev/null 2>&1; then
        engine=docker compose=(docker compose)
    elif command -v podman-compose > /dev/null 2>&1; then
        engine=podman compose=(podman-compose)
    elif podman compose version > /dev/null 2>&1; then
        engine=podman compose=(podman compose)
    else
        bad "Neither 'docker compose' nor 'podman-compose' was found."
        exit 1
    fi
    if ! "$engine" info > /dev/null 2>&1; then
        bad "$engine is installed but not running. Start it first."
        exit 1
    fi
}

android_running() {
    [ "$("$engine" inspect -f '{{.State.Running}}' "$CONTAINER" 2> /dev/null)" = true ]
}

# Opens a URL or a folder with the desktop's own program for it.
open_with_desktop() {
    if command -v xdg-open > /dev/null 2>&1; then
        xdg-open "$1" > /dev/null 2>&1 &
    elif command -v open > /dev/null 2>&1; then
        open "$1"
    fi
}

# Waits for the desktop to answer, two minutes at most, and opens it.
open_desktop() {
    local spinner=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) tenths=0
    $live || echo "Waiting for the desktop..."
    while [ $tenths -lt 1200 ]; do
        if [ $((tenths % 20)) -eq 0 ] && curl -s -m 2 -o /dev/null "$URL/"; then
            $live && printf '\r\033[K'
            open_with_desktop "$URL"
            good "The desktop is at ${cyan}$URL${off}"
            return 0
        fi
        if $live; then
            printf '\r%s Waiting for the desktop... ' "${cyan}${spinner[tenths % 10]}${off}"
            sleep 0.1
            tenths=$((tenths + 1))
        else
            sleep 2
            tenths=$((tenths + 20))
        fi
    done
    $live && printf '\r\033[K'
    return 1
}

# Opens the Android screen in the browser, starting Android first if needed.
# Leaves behind in $fresh whether it had to.
start() {
    local ok=true
    fresh=false
    if ! android_running; then
        step "Starting Android (the first start downloads several GB)"
        fresh=true
        "${compose[@]}" up -d || ok=false
    fi
    if $ok && open_desktop; then
        if $fresh; then
            echo "  Android needs about a minute to boot."
        fi
        return 0
    fi
    echo
    bad "Something went wrong. Recent log:"
    "${compose[@]}" logs --tail 25
    return 1
}

record() {
    if ! android_running; then
        bad "Android is not running. Start it first."
        return 1
    fi
    "${compose[@]}" --profile record run --rm recorder "$@"
}

# Plays a recording while it is being made, from a second before its end, so
# that there is always something left to play. The file is only read, which
# the recording does not notice. Without a name it is the newest recording.
listen() {
    local file='' candidate ms
    if ! command -v ffplay > /dev/null 2>&1; then
        bad "ffplay was not found. It comes with FFmpeg: install that first."
        return 1
    fi
    if [ $# -gt 0 ]; then
        file=recordings/${1%.wav}.wav
    else
        for candidate in recordings/*.wav; do
            if [ -e "$candidate" ] && { [ -z "$file" ] || [ "$candidate" -nt "$file" ]; }; then
                file=$candidate
            fi
        done
    fi
    if [ ! -s "$file" ]; then
        bad "There is no recording to listen to. Start one first, in another terminal."
        return 1
    fi
    # 192 bytes are a millisecond of 48 kHz, 16 bit, stereo.
    ms=$(($(wc -c < "$file") / 192 - 1000))
    if [ $ms -lt 0 ]; then
        ms=0
    fi
    echo "Listening to $file, a second behind - press Ctrl+C to stop"
    # The header's length is out of date, and the file's end is not the end.
    ffplay -nodisp -nostats -loglevel error -probesize 32 -analyzeduration 0 \
        -follow 1 -ignore_length 1 -ss "$((ms / 1000)).$(printf '%03d' $((ms % 1000)))" -i "$file"
}

recordings() {
    echo "The recordings are in $PWD/recordings"
    open_with_desktop "$PWD/recordings"
}

stop() {
    step "Stopping Android"
    "${compose[@]}" down
}

status() {
    if android_running; then
        echo "${green}●${off} Android is running: ${cyan}$URL${off}"
    else
        echo "${faint}○${off} Android is not running."
    fi
    echo
    "${compose[@]}" ps
    echo
    "${compose[@]}" logs --tail 25
}

# "update" fetches the new version and hands over to it for the rest, so
# that the rebuild is done the way the new version wants it.
update() {
    step "Fetching the latest version"
    if ! git pull; then
        echo
        bad "git pull failed, nothing was changed. See the message above."
        return 1
    fi
    exec "$self" _rebuild "$@"
}

rebuild() {
    step "Rebuilding the containers"
    "${compose[@]}" --profile record build || return 1
    if android_running; then
        step "Restarting Android with the new version"
        "${compose[@]}" down && start
    else
        good "Up to date."
    fi
}

# ------------------------------------------------------------------ menu
#
# The menu has the terminal's second screen to itself. Whatever it starts
# runs on the ordinary screen, where the output is still there to read
# after the menu is gone.

in_menu=false

enter_menu() {
    printf '\033[?1049h\033[?25l'
    in_menu=true
}

leave_menu() {
    if $in_menu; then
        printf '\033[?25h\033[?1049l'
        in_menu=false
    fi
}

pause() {
    echo
    read -rsn1 -p "${faint}Press any key to return to the menu${off} " || true
    echo
}

# Looks up what the menu shows about the world.
look() {
    if android_running; then running=true; else running=false; fi
    set -- recordings/*.wav
    if [ -e "$1" ]; then recorded=$#; else recorded=0; fi
}

# The entries: what each one says, depending on what was found.
entries() {
    keys=(1 2 3 4 5 6 7 q)
    labels=(
        "Start Android"
        "Record"
        "Listen to the recording"
        "Open the recordings folder"
        "Stop Android"
        "Status and log"
        "Update"
        "Quit"
    )
    hints=(
        "and open its screen in the browser"
        "start Android first"
        "while it is being made, with ffplay"
        ""
        "it is not running"
        ""
        "git pull, rebuild the containers"
        ""
    )
    if $running; then
        labels[0]="Open Android in the browser"
        hints[0]=""
        hints[1]="until Ctrl+C"
        hints[4]="its apps and logins are kept"
    fi
}

draw_menu() {
    local el=$'\033[K\n' screen i dim
    entries
    screen=$'\033[H'$el
    screen+="  ${faint}╭──────────────────────────────────────────────────────────╮${off}$el"
    screen+="  ${faint}│${off}  ${bold}${green}droidtap${off}  records what Android plays, and nothing else  ${faint}│${off}$el"
    screen+="  ${faint}╰──────────────────────────────────────────────────────────╯${off}$el$el"
    if $running; then
        screen+="   Android      ${green}●${off} running at ${cyan}$URL${off}$el"
    else
        screen+="   Android      ${faint}○ not running${off}$el"
    fi
    screen+="   Recordings   $recorded in ./recordings$el$el"
    for i in 0 1 2 3 4 5 6 7; do
        # Recording and stopping need a running Android.
        dim=''
        if ! $running && { [ $i -eq 1 ] || [ $i -eq 4 ]; }; then
            dim=$faint
        fi
        if [ $i -eq "$selected" ]; then
            screen+=" ${green}❯${off} ${bold}${dim}${keys[i]}  $(printf '%-28s' "${labels[i]}")${off}"
        else
            screen+="   ${faint}${keys[i]}${off}  ${dim}$(printf '%-28s' "${labels[i]}")${off}"
        fi
        screen+="  ${faint}${hints[i]}${off}$el"
    done
    screen+="$el   $message$el$el"
    screen+="  ${faint}↑↓ move · enter choose · 1-7 or q directly${off}$el"
    printf '%s\033[J' "$screen"
}

# Does what the selected entry says; fails when that is to quit.
choose() {
    local name
    message=''
    case "${keys[selected]}" in
        1)
            leave_menu
            if start; then
                message="${green}✓${off} Android is open in the browser."
                if $fresh; then
                    message+=" It needs about a minute to boot."
                fi
            else
                pause
            fi
            enter_menu
            ;;
        2)
            if ! android_running; then
                message="${red}✗${off} Android is not running. Start it first."
            else
                leave_menu
                read -r -p "Name of the recording (empty: date and time): " name || name=''
                # Ctrl+C ends the recording, not this menu.
                trap : INT
                record ${name:+"$name"}
                trap 'exit 130' INT
                pause
                enter_menu
            fi
            ;;
        3)
            leave_menu
            # Ctrl+C ends the listening, not this menu.
            trap : INT
            listen
            trap 'exit 130' INT
            pause
            enter_menu
            ;;
        4)
            recordings > /dev/null
            message="${green}✓${off} Opened $PWD/recordings"
            ;;
        5)
            leave_menu
            if stop; then
                message="${green}✓${off} Android is stopped."
            else
                pause
            fi
            enter_menu
            ;;
        6)
            leave_menu
            status
            pause
            enter_menu
            ;;
        7)
            # Comes back only if the update failed.
            leave_menu
            update menu
            pause
            enter_menu
            ;;
        q) return 1 ;;
    esac
    look
}

menu() {
    if ! $live || ! [ -t 0 ]; then
        plain_menu
        return
    fi
    local key rest pressed
    selected=0 message=''
    trap leave_menu EXIT
    trap 'exit 130' INT
    look
    enter_menu
    while true; do
        draw_menu
        IFS= read -rsn1 -t 5 key
        pressed=$?
        if [ $pressed -ne 0 ]; then
            # Nothing was pressed, so it is time to look at the world again.
            # Only bash 4 and later can tell that from the end of the input.
            if [ $pressed -le 128 ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
                break
            fi
            look
            continue
        fi
        if [ "$key" = $'\033' ]; then
            # An arrow key sends two more characters.
            rest=''
            IFS= read -rsn2 -t 1 rest
            case "$rest" in
                '[A' | OA) key=k ;;
                '[B' | OB) key=j ;;
            esac
        fi
        case "$key" in
            k) selected=$(((selected + 7) % 8)) ;;
            j) selected=$(((selected + 1) % 8)) ;;
            '') choose || break ;;
            [1-7])
                selected=$((key - 1))
                choose
                ;;
            q | Q) break ;;
        esac
    done
    leave_menu
}

# The menu for where there is no terminal to draw on.
plain_menu() {
    local choice name i
    while true; do
        look
        entries
        echo
        if $running; then
            echo "droidtap - Android is running ($URL)"
        else
            echo "droidtap - Android is not running"
        fi
        for i in 0 1 2 3 4 5 6 7; do
            echo "  ${keys[i]}) ${labels[i]}"
        done
        read -r -p "> " choice || break
        echo
        case "$choice" in
            1) start ;;
            2)
                read -r -p "Name of the recording (empty: date and time): " name || continue
                # Ctrl+C ends the recording, not this menu.
                trap : INT
                record ${name:+"$name"}
                trap - INT
                ;;
            3)
                trap : INT
                listen
                trap - INT
                ;;
            4) recordings ;;
            5) stop ;;
            6) status ;;
            7) update menu ;;
            q | Q) break ;;
            *) echo "Type one of 1-7, or q." ;;
        esac
    done
}

main() {
    styles
    # The commands that work without a container engine.
    case "${1:-}" in
        recordings)
            recordings
            return
            ;;
        listen)
            shift
            listen "$@"
            return
            ;;
    esac
    find_engine
    case "${1:-}" in
        "") menu ;;
        start) start ;;
        record)
            shift
            record "$@"
            ;;
        stop) stop ;;
        status) status ;;
        update) update ;;
        _rebuild)
            rebuild || exit 1
            if [ "${2:-}" = menu ]; then
                if $live; then
                    pause
                fi
                menu
            fi
            ;;
        *)
            echo "Usage: $0 [start | record [name] | listen [name] | recordings | stop | status | update]" >&2
            exit 2
            ;;
    esac
}

main "$@"
exit
