# Import pipeline

Imports JSON table dumps from a directory. **Does not load `script/export/*`** — only needs `*.json` files (from this app’s export or any compatible bundle).

All commands run from the **Rails app root** (`spp/`).

---

## Phase 3: Database import

**Script:** `script/import/import_all.rb`  
**Config:** `script/import/import_config.rb`

**What it does**

- Scans **`IMPORT_INPUT_DIR`** for `*.json` files (default `tmp/export/`).
- Maps each file to an ActiveRecord model by **table name** (e.g. `stories.json` → `Story`).
- Skips non-table JSON: `paperclip_manifest.json`, `asset_sync_report.json`, `import_report.json`.
- Skips **PostgreSQL views** (e.g. `stories_searches.json`).
- Imports with **`insert_all`** (no validations/callbacks).
- Handles story **join table** JSON (`authors_stories`, `stories_story_categories`, `stories_downloads`, etc.) separately when present.

**Run**

```bash
bundle exec rails runner script/import/import_all.rb
```

**Environment**

| Variable | Default | Meaning |
|----------|---------|---------|
| `IMPORT_INPUT_DIR` | `tmp/export` | Directory containing `*.json` table files |
| `IMPORT_SKIP_EXISTING` | `true` | Skip rows whose `id` already exists |
| `IMPORT_MIRROR_ASSETS` | off | `1` copies `assets/` → `public/<fog.directory>/` |
| `IMPORT_PURGE_AUTHORS_STORIES` | `true` | Purge `authors_stories` for imported story ids before insert |
| `IMPORT_BATCH_SIZE` | `500` | Batch size for `insert_all` |

**List tables that would be imported**

```bash
bundle exec rails runner script/import/list_tables.rb
```

---

## Phase 4: Searchkick restore

**Script:** `script/import/searchkick_restore.rb`

Reindexes models that (1) have `searchkick` and (2) have a matching `{table_name}.json` in the bundle.

```bash
bundle exec rails runner script/import/searchkick_restore.rb
```

| Variable | Meaning |
|----------|---------|
| `IMPORT_INPUT_DIR` | Same bundle directory |
| `SEARCHKICK_RESTORE_BATCH` | Batch size (default `200`) |
| `SEARCHKICK_ONLY` | e.g. `Language,Story` |

---

## Layout

```
script/import/
  import_config.rb
  import_helpers.rb
  import_all.rb
  searchkick_restore.rb
  list_tables.rb
  IMPORT.md
```

Export pipeline: **`script/export/`** and [EXPORT.md](../export/EXPORT.md).
