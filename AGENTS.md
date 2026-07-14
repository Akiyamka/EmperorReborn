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
