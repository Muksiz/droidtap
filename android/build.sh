#!/usr/bin/env bash
# Rebuilds volume.dex from Volume.java. Needs a JDK and d8 (from the Android
# SDK build-tools, or D8="java -cp r8.jar com.android.tools.r8.D8").
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
javac -source 17 -target 17 -Xlint:-options -d "$tmp" Volume.java
${D8:-d8} --min-api 30 --output "$tmp" "$tmp/Volume.class"
mv "$tmp/classes.dex" volume.dex
