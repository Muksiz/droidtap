#!/usr/bin/env bash
# Starts, stops and records with droidtap on Linux or macOS; the counterpart
# of droidtap.bat. Usage:
#   ./droidtap.sh start | record [name] | stop | status | update
set -u
cd "$(dirname "$0")"

URL=http://localhost:6080

if docker compose version > /dev/null 2>&1; then
    compose=(docker compose)
elif command -v podman-compose > /dev/null 2>&1; then
    compose=(podman-compose)
elif podman compose version > /dev/null 2>&1; then
    compose=(podman compose)
else
    echo "Neither 'docker compose' nor 'podman-compose' was found." >&2
    exit 1
fi

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
    echo "Starting Android..."
    if "${compose[@]}" up -d "$@" && open_desktop; then
        return 0
    fi
    echo
    echo "Something went wrong. Recent log:"
    "${compose[@]}" logs --tail 25
    return 1
}

case "${1:-}" in
    start)
        start
        ;;
    record)
        shift
        "${compose[@]}" --profile record run --rm recorder "$@"
        ;;
    stop)
        echo "Stopping Android..."
        "${compose[@]}" down
        ;;
    status)
        "${compose[@]}" ps
        echo
        "${compose[@]}" logs --tail 25
        ;;
    update)
        echo "Fetching the latest version..."
        if ! git pull; then
            echo
            echo "git pull failed, nothing was changed. See the message above."
            exit 1
        fi
        "${compose[@]}" --profile record build && start
        ;;
    *)
        echo "Usage: $0 start | record [name] | stop | status | update" >&2
        exit 2
        ;;
esac
