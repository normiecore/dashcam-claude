#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
classes_dir="$(mktemp -d)"
trap 'rm -rf "$classes_dir"' EXIT
java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java"
if command -v javac >/dev/null 2>&1; then
    compiler=(javac)
elif [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
    compiler=("$JAVA_HOME/bin/javac")
else
    # Some cloud JDK packages include jdk.compiler before installing the javac launcher.
    compiler=("$java_bin" -m jdk.compiler/com.sun.tools.javac.Main)
fi
"${compiler[@]}" -encoding UTF-8 -d "$classes_dir" \
    "$project_dir/app/src/main/java/com/daz/dashcam/RetentionPolicy.java" \
    "$project_dir/app/src/main/java/com/daz/dashcam/RecordingStore.java" \
    "$project_dir/core-tests/RecordingStoreTest.java"
"$java_bin" -cp "$classes_dir" com.daz.dashcam.RecordingStoreTest
