#!/usr/bin/env bash
# Starts, stops, records with and updates droidtap on Linux or macOS; the
# counterpart of droidtap.bat. Without a command it shows a menu. Usage:
#   ./droidtap.sh [start | record [name] | stop | open | status | update]
set -u
cd "$(dirname "$0")"
self=./$(basename "$0")

URL=http://localhost:6080
CONTAINER=droidtap-emulator

# Everything is in functions, called from the last line: "update" replaces
# this file, and bash would otherwise go on reading the new one halfway.

find_engine() {
    if docker compose version > /dev/null 2>&1; then
        engine=docker compose=(docker compose)
    elif command -v podman-compose > /dev/null 2>&1; then
        engine=podman compose=(podman-compose)
    elif podman compose version > /dev/null 2>&1; then
        engine=podman compose=(podman compose)
    else
        echo "Neither 'docker compose' nor 'podman-compose' was found." >&2
        exit 1
    fi
    if ! "$engine" info > /dev/null 2>&1; then
        echo "$engine is installed but not running. Start it first." >&2
        exit 1
    fi
}

android_running() {
    [ "$("$engine" inspect -f '{{.State.Running}}' "$CONTAINER" 2> /dev/null)" = true ]
}

open_desktop() {
    echo "Waiting for the desktop..."
    for _ in $(seq 1 60); do
        if curl -s -o /dev/null "$URL/"; then
            if command -v xdg-open > /dev/null 2>&1; then
                xdg-open "$URL" > /dev/null 2>&1 &
            elif command -v open > /dev/null 2>&1; then
                open "$URL"
            fi
            echo "The desktop is at $URL. Android needs about a minute to boot."
            return 0
        fi
        sleep 2
    done
    return 1
}

start() {
    echo "Starting Android... (the first start downloads several GB)"
    if "${compose[@]}" up -d && open_desktop; then
        return 0
    fi
    echo
    echo "Something went wrong. Recent log:"
    "${compose[@]}" logs --tail 25
    return 1
}

record() {
    if ! android_running; then
        echo "Android is not running. Start it first." >&2
        return 1
    fi
    "${compose[@]}" --profile record run --rm recorder "$@"
}

open_screen() {
    if ! android_running; then
        echo "Android is not running. Start it first." >&2
        return 1
    fi
    open_desktop
}

stop() {
    echo "Stopping Android..."
    "${compose[@]}" down
}

status() {
    if android_running; then
        echo "Android is running: $URL"
    else
        echo "Android is not running."
    fi
    echo
    "${compose[@]}" ps
    echo
    "${compose[@]}" logs --tail 25
}

# "update" fetches the new version and hands over to it for the rest, so
# that the rebuild is done the way the new version wants it.
update() {
    echo "Fetching the latest version..."
    if ! git pull; then
        echo
        echo "git pull failed, nothing was changed. See the message above."
        return 1
    fi
    exec "$self" _rebuild "$@"
}

rebuild() {
    echo "Rebuilding the containers..."
    "${compose[@]}" --profile record build || return 1
    if android_running; then
        echo "Restarting Android with the new version..."
        "${compose[@]}" down && start
    else
        echo "Up to date."
    fi
}

menu() {
    while true; do
        echo
        if android_running; then
            echo "droidtap - Android is running ($URL)"
        else
            echo "droidtap - Android is not running"
        fi
        echo "  1) Start Android"
        echo "  2) Record"
        echo "  3) Stop Android"
        echo "  4) Open the Android screen in the browser"
        echo "  5) Status and log"
        echo "  6) Update (git pull, rebuild the containers)"
        echo "  q) Quit"
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
            3) stop ;;
            4) open_screen ;;
            5) status ;;
            6) update menu ;;
            q | Q) break ;;
            *) echo "Type one of 1-6, or q." ;;
        esac
    done
}

main() {
    find_engine
    case "${1:-}" in
        "") menu ;;
        start) start ;;
        record)
            shift
            record "$@"
            ;;
        stop) stop ;;
        open) open_screen ;;
        status) status ;;
        update) update ;;
        _rebuild)
            rebuild || exit 1
            if [ "${2:-}" = menu ]; then
                menu
            fi
            ;;
        *)
            echo "Usage: $0 [start | record [name] | stop | open | status | update]" >&2
            exit 2
            ;;
    esac
}

main "$@"
exit
