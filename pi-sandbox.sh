#!/usr/bin/env bash
# Launch pi inside a sandboxed container with read/write access to a
# specified directory (and everything under it).
#
# Usage:
#   ./pi-sandbox.sh [DIR] [pi args...]
#
#   DIR   optional; directory to mount at its own path (default: $PWD)
#         e.g. ./pi-sandbox.sh ~/projects/foo exec "summarize this repo"
#   pi    args after DIR (or all args, if no DIR) are passed straight to pi
#         e.g. ./pi-sandbox.sh exec "summarize this repo"   (uses $PWD)
#
#   spi resume [filter]   list recent pi sessions from the shared session
#                         store and relaunch the selected one in a container
#                         whose cwd matches the session's directory.
#                         filter matches dir, name, or session id (substring).
#
# Note: this manages PI sessions (~/.pi/agent/sessions). If you also run the
# qwen CLI in the container, its session store is separate (~/.qwen).
#
# The container can read and write DIR and all its subdirectories.
# DIR is mounted at its ORIGINAL absolute path (not /workspace), so pi
# sessions are stored under the real project path in the shared
# ~/.pi/agent/sessions/ and host/container resume pickers match up.
# It also mounts your host ~/.pi/agent so pi keeps the same settings
# (llama.cpp server, pi-llama-cpp package, etc.) and session history.
set -euo pipefail

IMAGE="pi-sandbox"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$HERE/Dockerfile.pi"

# --- spi resume ----------------------------------------------------------
# List recent sessions and relaunch the selected one in a container whose
# cwd matches the session's directory (same-path mount => local session
# match). Works from the host because the session store is shared.
if [ "${1:-}" = "resume" ]; then
  shift
  FILTER="${*:-}"

  SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
  if [ ! -d "$SESSIONS_DIR" ]; then
    echo "error: no pi session store at $SESSIONS_DIR" >&2
    exit 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "error: node is required for 'spi resume' (or use 'pi -r' directly)" >&2
    exit 1
  fi

  # Emit one TSV row per session: mtime_ms, id, cwd, name
  # (name = latest session_info entry; empty if the session is unnamed)
  scan_sessions() {
    node -e '
const fs = require("fs"), path = require("path");
const root = process.argv[1];
let dirs = [];
try { dirs = fs.readdirSync(root, { withFileTypes: true }); } catch {}
const rows = [];
for (const d of dirs) {
  if (!d.isDirectory()) continue;
  const dir = path.join(root, d.name);
  let files = [];
  try { files = fs.readdirSync(dir); } catch { continue; }
  for (const f of files) {
    if (!f.endsWith(".jsonl")) continue;
    const p = path.join(dir, f);
    try {
      const st = fs.statSync(p);
      const data = fs.readFileSync(p, "utf8");
      const nl = data.indexOf("\n");
      let hdr = null;
      try { hdr = JSON.parse(nl === -1 ? data : data.slice(0, nl)); } catch {}
      if (!hdr || hdr.type !== "session" || !hdr.id) continue;
      let name = "";
      const lines = data.split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        const l = lines[i];
        if (!l) continue;
        let e = null;
        try { e = JSON.parse(l); } catch { continue; }
        if (e.type === "session_info") { name = (e.name || "").trim(); break; }
      }
      const clean = (s) => String(s || "").replace(/\t/g, " ");
      rows.push([Math.floor(st.mtimeMs), hdr.id, clean(hdr.cwd || "?"), clean(name)].join("\t"));
    } catch {}
  }
}
if (rows.length) process.stdout.write(rows.join("\n") + "\n");
' "$SESSIONS_DIR"
  }

  list="$(scan_sessions | sort -rn | head -n 500)"
  if [ -n "$FILTER" ]; then
    list="$(printf "%s\n" "$list" | grep -i -- "$FILTER" || true)"
  fi
  if [ -z "$list" ]; then
    echo "no pi sessions found${FILTER:+ matching "$FILTER"} in $SESSIONS_DIR"
    exit 0
  fi

  fmt_date() {
    local sec=$(( ${1%%.*} / 1000 ))
    date -d "@$sec" '+%Y-%m-%d %H:%M' 2>/dev/null \
      || date -r "$sec" '+%Y-%m-%d %H:%M' 2>/dev/null \
      || printf '%s' "$sec"
  }

  capped=0
  if [ "$(printf "%s\n" "$list" | wc -l)" -gt 40 ]; then
    list="$(printf "%s\n" "$list" | head -n 40)"
    capped=1
  fi

  echo "Recent pi sessions (newest first):"
  idx=0
  rows=()
  while IFS=$'\t' read -r mtime sid cwd name; do
    [ -n "${sid:-}" ] || continue
    idx=$(( idx + 1 ))
    rows+=("$sid"$'\t'"$cwd"$'\t'"${name:-}"$'\t'"$mtime")
    printf "  %2d  %s  %s\n" "$idx" "$(fmt_date "$mtime")" "${cwd:0:44}"
    [ -n "${name:-}" ] && printf "      %s\n" "name: ${name:0:60}"
  done <<< "$list"
  if [ "$capped" -eq 1 ]; then
    echo "(showing 40 most recent — narrow with: spi resume <filter>)"
  fi
  echo

  sel=""
  if [ ! -t 0 ]; then
    if [ "$idx" -eq 1 ]; then sel=1; else
      echo "non-interactive stdin: use a filter that matches exactly one session" >&2
      exit 1
    fi
  else
    printf "Select a session [1-%d] (q to quit): " "$idx"
    read -r sel || sel=q
  fi
  case "$sel" in
    q|"") exit 0 ;;
    *[!0-9]*) echo "invalid selection: $sel" >&2; exit 1 ;;
  esac
  if [ "$sel" -lt 1 ] || [ "$sel" -gt "$idx" ]; then
    echo "out of range: $sel" >&2
    exit 1
  fi

  IFS=$'\t' read -r sid cwd name mtime <<< "${rows[$(( sel - 1 ))]}"
  if [ -d "$cwd" ]; then
    echo "launching: spi $cwd --session $sid"
    exec "$0" "$cwd" --session "$sid"
  else
    echo "note: $cwd does not exist on the host; resuming from $PWD (global session lookup)"
    exec "$0" --session "$sid"
  fi
fi

# --- args ---------------------------------------------------------------
if [ $# -gt 0 ] && [ -d "$1" ]; then
  DIR="$1"
  shift
else
  if [ $# -gt 0 ] && [[ "$1" == */* ]]; then
    echo "error: '$1' is not a directory" >&2
    exit 1
  fi
  DIR="$PWD"
fi
DIR="$(cd "$DIR" && pwd)"
if [ "$DIR" = "/" ]; then
  echo "error: refusing to mount / at / (would hide the container filesystem)" >&2
  exit 1
fi

# --- prerequisites ------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed" >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [ ! -f "$DOCKERFILE" ]; then
    echo "error: image '$IMAGE' not found and $DOCKERFILE does not exist" >&2
    exit 1
  fi
  echo "building image '$IMAGE' (first run)..." >&2
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$HERE"
fi

# --- optional GitHub credentials ---------------------------------------
# Mount host credentials so pi inside the container can clone/push:
#   ~/.git-credentials  -> /root/.git-credentials, with git told to use the
#                          "store" helper via GIT_CONFIG_* (the host
#                          ~/.gitconfig is not mounted)
#   ~/.ssh              -> /root/.ssh (for git@github.com: remotes)
#   GITHUB_TOKEN/GH_TOKEN env vars, if exported in your shell
CRED_ARGS=()
if [ -f "$HOME/.git-credentials" ]; then
  CRED_ARGS+=( -v "$HOME/.git-credentials:/root/.git-credentials"
               -e GIT_CONFIG_COUNT=1 \
               -e GIT_CONFIG_KEY_0=credential.helper \
               -e GIT_CONFIG_VALUE_0=store )
fi
[ -d "$HOME/.ssh" ] && CRED_ARGS+=( -v "$HOME/.ssh:/root/.ssh" )
[ -n "${GITHUB_TOKEN:-}" ] && CRED_ARGS+=( -e GITHUB_TOKEN )
[ -n "${GH_TOKEN:-}" ] && CRED_ARGS+=( -e GH_TOKEN )

# --- run ----------------------------------------------------------------
# -t only makes sense with a TTY (interactive chat). Drop it when piped.
TTY_FLAG="-i"
if [ -t 0 ]; then TTY_FLAG="-it"; fi

exec docker run --rm \
  $TTY_FLAG \
  --network host \
  -v "$HOME/.pi/agent:/root/.pi/agent" \
  -v "$DIR:$DIR" \
  -w "$DIR" \
  "${CRED_ARGS[@]}" \
  "$IMAGE" "$@"
