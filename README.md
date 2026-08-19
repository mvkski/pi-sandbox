# pi-sandbox

Run the [pi coding agent](https://github.com/earendil-works/pi) in a sandboxed
Docker container with per-directory isolation — and keep one shared session
store across host and container so sessions resume seamlessly.

## Files

| File | Purpose |
| --- | --- |
| `pi-sandbox.sh` | The launcher. Add it to your `$PATH` (or alias it `spi` in your bashrc). |
| `Dockerfile.pi` | Node 22 + pi image, entrypoint is `pi` itself. Built once, cached locally. |

## Setup

```bash
# one-liner alias in your ~/.bashrc (adjust path):
alias spi=/path/to/pi-sandbox.sh
```

That's it. The docker image `pi-sandbox` is built automatically on first run.

## Usage

```bash
spi [DIR] [pi args...]
```

- `DIR` is mounted at its **own absolute path** (not `/workspace`), so pi
  sessions are stored under the real project path in the shared
  `~/.pi/agent/sessions/` — host and container resume pickers match up.
- All remaining args go straight to `pi` (the image's entrypoint).

Examples:

```bash
spi                            # current dir, interactive
spi ~/projects/foo             # a specific project
spi ~/projects/foo -c          # continue most recent session for that dir
spi exec "summarize this repo" # non-interactive (TTY flag drops -t when piped)
```

### `spi resume`

List recent pi sessions from the shared session store and relaunch the
selected one in a container whose cwd matches the session's directory:

```bash
spi resume              # numbered list (40 most recent), pick one
spi resume Qwen         # pre-filter by dir / name / session id
```

The launch is just `spi <session cwd> --session <id>`; if the session's
directory no longer exists, it falls back to a global session-ID lookup from
your current directory. With non-interactive stdin, a filter that matches
exactly one session auto-launches it.

## How it works

One `docker run` with two bind mounts:

```bash
docker run --rm -it --network host \
  -v "$HOME/.pi/agent:/root/.pi/agent" \
  -v "$DIR:$DIR" -w "$DIR" \
  pi-sandbox "$@"
```

- `~/.pi/agent` (settings, auth, session history) is shared both ways, so
  container sessions are host sessions.
- The project dir at its own path keeps pi's per-cwd session folders
  (`~/.pi/agent/sessions/<path-with-dashes>/`) identical on host and in the
  container.

The `spi resume` lister is a small embedded `node -e` scan of the session
JSONL files (header for `id`/`cwd`, last `session_info` entry for the
display name) — no daemons, no extra state. `PI_SESSIONS_DIR` overrides the
store location.

## GitHub credentials

If the following exist on the host, they are mounted into the container so pi
inside can clone/push (each is passed through only when present):

| Host source | Container target | Purpose |
| --- | --- | --- |
| `~/.git-credentials` | `/root/.git-credentials` | HTTPS pushes via git's `store` helper (enabled through `GIT_CONFIG_*` env vars, since the host `~/.gitconfig` is not mounted) |
| `~/.ssh` | `/root/.ssh` | `git@github.com:` SSH remotes |
| `$GITHUB_TOKEN` / `$GH_TOKEN` (if exported) | same env vars | API access, `gh`-style flows |

Prefer scoped access? Export a fine-grained PAT as `GITHUB_TOKEN` in your
shell instead of relying on `~/.ssh`, or edit the `CRED_ARGS` block in
`pi-sandbox.sh` to mount a single read-only token file.

## Notes

- Refuses to run with `DIR=/` (would hide the container filesystem).
- Requires `docker` and (for `spi resume`) `node` on the host.
- Manages **pi** sessions. If you also run other agents (e.g. the qwen CLI)
  in the container, their session stores are separate.
