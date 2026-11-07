#!/usr/bin/env bash
set -euo pipefail

# Builds one lecture (or all of them) with `zig build`, and optionally runs it or its tests.

# Every lecture is its own Zig package (a build.zig next to a build.zig.zon), so this script
# only chooses the directory and the flags.
cd "$(dirname "$0")"

if ! command -v zig >/dev/null 2>&1; then
  echo "zig is not on the PATH. Install Zig 0.17.1 from https://ziglang.org/download/ (see README.md)." >&2
  exit 1
fi

# Lecture

# Every lecture_N/ with a build.zig, in numeric order (sort -V puts lecture_10 after lecture_9).
mapfile -t lectures < <(
  for script in lecture_*/build.zig; do
    echo "${script%%/*}"
  done | sort -V
)

echo
echo "0) All lectures"
for i in "${!lectures[@]}"; do
  echo "$((i + 1))) ${lectures[$i]}"
done
echo

read -rp "Choose a lecture [0-${#lectures[@]}]: " lecture_choice

if [[ "$lecture_choice" == 0 ]]; then
  TARGET="all"
elif [[ "$lecture_choice" =~ ^[0-9]+$ ]] && (( lecture_choice >= 1 && lecture_choice <= ${#lectures[@]} )); then
  TARGET="${lectures[$((lecture_choice - 1))]}"
else
  echo "Invalid choice"
  exit 1
fi

# Configuration

# Running needs a single lecture, so "All lectures" offers the builds and the tests only.
if [[ "$TARGET" == all ]]; then
  echo "
Build                      Test
 1) Debug                   4) Debug
 2) ReleaseSafe             5) ReleaseSafe
 3) ReleaseFast
"
  read -rp "Choose [1-5, Enter for 1]: " choice
  choice="${choice:-1}"
  max=5
else
  echo "
Build                      Test                       Build & run
 1) Debug                   4) Debug                   6) Debug
 2) ReleaseSafe             5) ReleaseSafe             7) ReleaseSafe
 3) ReleaseFast                                        8) ReleaseFast
"
  read -rp "Choose [1-8, Enter for 6]: " choice
  choice="${choice:-6}"
  max=8
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > max )); then
  echo "Invalid choice: $choice" >&2
  exit 1
fi

# `zig build` steps: the default step installs, `test` runs the tests, `run` runs the program.
# -Doptimize picks the optimization mode: debug (safety checks, no optimization), safe (both), fast (no checks).
case "$choice" in
  1) step=install; optimize=debug ;;
  2) step=install; optimize=safe ;;
  3) step=install; optimize=fast ;;
  4) step=test;    optimize=debug ;;
  5) step=test;    optimize=safe ;;
  6) step=run;     optimize=debug ;;
  7) step=run;     optimize=safe ;;
  8) step=run;     optimize=fast ;;
esac

# Build

if [[ "$TARGET" == all ]]; then
  for lecture in "${lectures[@]}"; do
    echo
    echo "=== $lecture: zig build $step -Doptimize=$optimize ==="
    (cd "$lecture" && zig build "$step" "-Doptimize=$optimize")
  done
  exit 0
fi

echo
echo "=== $TARGET: zig build $step -Doptimize=$optimize ==="
cd "$TARGET"
exec zig build "$step" "-Doptimize=$optimize"
