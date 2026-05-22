# Import pipeline (Phase 3–4)

Restore a bundle produced by the **export** pipeline into a database and rebuild Elasticsearch indexes for exported Searchkick models. **Export is documented separately in [EXPORT.md](./EXPORT.md).**

All commands run from the **Rails application root** (`spp/`).

**Recommended:** use a **disposable or empty** target database. Imports use **explicit primary keys**; clashes with existing rows, FKs, or unique indexes (e.g. `users.email`) are possible unless you use skip-existing behavior.

---

## Phase 3: Database import

**Script:** `script/export/import_all.rb`  
**Implementation:** `script/export/import_helpers.rb`

**Prerequisites**

- Bundle directory with JSON from `export_all.rb` (same filenames as export).
- **`authors_stories.json`** present if you need story ↔ author HABTM links (re-export with current `export_all.rb` if missing).
- Optional: run **Phase 2** (`sync_assets.rb`) so `assets/` exists in the bundle; see **`IMPORT_MIRROR_ASSETS`** below.

**What it does**

- Imports in **FK-safe order**: Language → Organization → User → Illustration → IllustrationCrop → Story → Page → Box.
- Uses **`insert_all`** only (no AR validations/callbacks on insert — no Searchkick fires, no Paperclip processing from callbacks).
- **`Searchkick.callbacks(false)`** for the whole run.
- **`IMPORT_SKIP_EXISTING`** (default on): skip rows whose `id` already exists.
- After each table on **PostgreSQL**, runs **`reset_pk_sequence!`** on that table.
- Imports **`authors_stories`** after core tables: optionally **deletes** existing `(user_id, story_id)` rows for **story ids present in the bundle’s `stories.json`**, then batch inserts from **`authors_stories.json`**.
- Optional: **`IMPORT_MIRROR_ASSETS=1`** copies `bundle/assets/*` into `public/<Settings.fog.directory>/` for a dev-style Paperclip layout.

**Run**

```bash
bundle exec rails runner script/export/import_all.rb
```

**Environment**

| Variable | Default | Meaning |
|----------|---------|---------|
| `IMPORT_INPUT_DIR` | `tmp/export` | Directory containing the JSON bundle |
| `IMPORT_REPORT_PATH` | `<input>/import_report.json` | Written summary of the import |
| `IMPORT_SKIP_EXISTING` | `true` | Skip inserting rows if `id` already exists |
| `IMPORT_MIRROR_ASSETS` | off (`1` to enable) | Copy `assets/` → `public/<fog.directory>/` |
| `IMPORT_PURGE_AUTHORS_STORIES` | `true` | Before inserting join rows, delete `authors_stories` for imported `story_id`s |

**Note on assets**

If you do **not** mirror, you must still satisfy Paperclip for your environment (e.g. files on Fog, or paths under `public/`). Mirroring is **opt-in** to avoid overwriting `public/` by accident.

---

## Phase 4: Searchkick / Elasticsearch restore

**Script:** `script/export/searchkick_restore.rb`

**Prerequisites**

- Phase 3 completed (rows in DB).
- **Elasticsearch** available to `Searchkick.client`.

**Models reindexed** (must match export set that use Searchkick)

- Language  
- Organization  
- User  
- Illustration  
- Story  

(Page, Box, IllustrationCrop are not Searchkick-indexed in this app.)

**What it does**

- Reads **ids** from the **same** JSON files in `IMPORT_INPUT_DIR` as Phase 3.
- **`Searchkick.callbacks(false)`** for the run.
- For each model: **`unscoped.where(id: …).in_batches`** → **`searchkick_index.reindex(relation, mode: :inline)`** (batch bulk index, no async callback queue from this path).
- Optionally refreshes the index per model (see config).

**Run**

```bash
bundle exec rails runner script/export/searchkick_restore.rb
```

**Environment**

| Variable | Meaning |
|----------|---------|
| `IMPORT_INPUT_DIR` | Same bundle directory as Phase 3 (default `tmp/export`) |
| `SEARCHKICK_RESTORE_BATCH` | Records per batch (default `200`) |
| `SEARCHKICK_RESTORE_REFRESH` | `0` / `false` to skip per-model index refresh |
| `SEARCHKICK_ONLY` | Comma-separated model names, e.g. `Language,Story` |

**Allowed `SEARCHKICK_ONLY` names:** `Language`, `Organization`, `User`, `Illustration`, `Story`.

---

## End-to-end order (reference)

1. **Source app:** `export_all.rb` → optional `verify_export.rb`  
2. **Source app:** `sync_assets.rb` (optional binaries under `assets/`)  
3. **Target app / DB:** `import_all.rb` (optional `IMPORT_MIRROR_ASSETS=1`)  
4. **Target app:** `searchkick_restore.rb`  

---

## Related Ruby modules

| File | Role |
|------|------|
| `export_config.rb` | `IMPORT_*`, `SEARCHKICK_RESTORE_*`, `searchkick_restorable_classes` |
| `import_helpers.rb` | Coercion, `insert_all`, sequences, `authors_stories`, optional asset mirror |

---

## Troubleshooting

| Issue | Suggestion |
|-------|------------|
| Duplicate key / unique violation | Use empty DB or `IMPORT_SKIP_EXISTING=true`; avoid duplicate emails if inserting “new” ids. |
| Missing author links | Ensure `authors_stories.json` is in the bundle (re-run export). |
| Images 404 after import | Run asset sync before import; or `IMPORT_MIRROR_ASSETS=1`; or align storage with your env. |
| Search does not find records | Run `searchkick_restore.rb`; confirm Elasticsearch is up and index names match env. |
