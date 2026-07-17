# Emperor Rules Editor

NeutralinoJS editor for EmperorReborn's `assets/converted/rules.db`.

The database is generated from `assets/raw_original_content/MODEL/Rules.txt`
and can also be enriched with art bindings from
`assets/raw_original_content/MODEL/ArtIni.txt`.

## Requirements

- Node.js 24 or newer. The app uses the built-in `node:sqlite` module.
- NeutralinoJS runtime files, downloaded with `npm run neutralino:update`.

## Install

```sh
npm install
npm run neutralino:update
```

## Run

From the EmperorReborn repository root:

```sh
make rules-editor
```

Or directly from `tools/rules_editor`:

```sh
npm start
```

By default the app opens `assets/converted/rules.db`. To open another database:

```sh
RULES_DB=/path/to/rules.db npm start
```

If the shell does not export display variables, run with an explicit display:

```sh
DISPLAY=:0 npm start
```

## Checks

```sh
npm run check
npm test
```

`npm test` only verifies the SQLite data layer and does not open a window.

## Rebuild Database

```sh
python3 parse_rules.py ../../assets/raw_original_content/MODEL/Rules.txt schema.sql /tmp/rules.db ../../assets/raw_original_content/MODEL/ArtIni.txt
```

## Architecture

- NeutralinoJS renders the static UI from `ui/`.
- The custom extension in `extensions/rules-db.mjs` exposes the database API over Neutralino's extension IPC.
- SQLite access stays in `app/db.mjs` and uses Node's built-in `node:sqlite`.

## Features

- Browse every table in the normalized rules database.
- Browse imported ArtIni visual resources and side recolor settings.
- Search rows across all visible table columns.
- Sort by any column and page through large tables.
- Edit non-primary-key fields in the row detail pane.
- Insert new rows, including composite-primary-key junction rows.
- Delete selected rows when foreign-key constraints allow it.
- Show foreign-key values with referenced labels when a referenced table has a `name` column.
- Create timestamped `.bak` copies of the database before risky edits.
