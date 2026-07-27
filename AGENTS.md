# Repository guidance

## Emperor rules data

All original Emperor: Battle for Dune rules required by this repository are
available locally. Do not search for or download rules data from external
sites.

- `assets/raw_original_content/MODEL/Rules.txt` is the raw original rules file.
  The filename is case-sensitive (`Rules.txt`). Use it when original comments,
  spelling, or source context are relevant.
- `assets/converted/rules.db` is the normalized SQLite rules database and the
  source of truth for typed/queryable rule data.
- `assets/converted/schema.sql` documents the database schema, column meanings,
  relationships, and conversion decisions. Read the relevant schema section
  before querying or changing rules-dependent behavior.
- `assets/converted/rules/` contains Godot resources exported from the database
  for runtime consumption. Treat these as generated representations, not as an
  independent rules source.

Prefer read-only `sqlite3 assets/converted/rules.db ...` queries for structured
analysis. Cross-check the corresponding entry in `Rules.txt` when units or
conversion semantics (for example comments describing units per tick/update)
matter.

## Godot container

Run commands that use `tools/godot-container` sequentially. Parallel runs share
the same container and `/workspace` mount, so they interfere with one another
and can produce invalid project-path or incomplete class-loading errors that
look like test failures.

### A headless run that "hangs" is usually a compile error, not slow work

A `godot --headless --script res://....gd` invocation for a one-shot
converter/test should finish in seconds. If it's still running after a while
with near-zero CPU, that is not "still working" — a `SceneTree` script that
throws a parse/compile error (bad type inference, a broken `preload`, etc.)
never reaches its `quit()` call, so the process falls through to Godot's idle
main loop and sits there forever doing nothing, consuming ~0% CPU. It looks
alive in `ps`/`podman ps` and gives no other external signal that anything is
wrong.

Don't pipe the run through `| tail` (or any buffering command) and then wait —
that hides `SCRIPT ERROR:`/`Parse Error:` lines until the process exits, and
since it never exits on its own, you'll wait forever with an empty buffer and
no way to tell a hang from real progress. Instead:

- Run with a bounded `timeout` and let stdout/stderr print directly (or `tee`
  to a file you can `cat` mid-run) so `SCRIPT ERROR`/`Parse Error` output is
  visible immediately, not buffered behind the process exit.
- If a background run has been alive for a while, check `ps`/`podman top` CPU%
  for that PID before continuing to wait — near-zero CPU on a script that
  should be doing real work is the signal to go read its output now rather
  than keep waiting.
- On any hang, kill it, fix the reported error, and rerun — don't assume it
  will eventually finish.
