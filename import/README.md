# Import tooling

Independent of **`script/export/`**. Import reads **`*.json`** from a directory; it does not require export scripts or `Export::Config`.

| Document | Scope |
|----------|--------|
| [IMPORT.md](./IMPORT.md) | Import + Searchkick restore |

```bash
bundle exec rails runner script/import/import_all.rb
bundle exec rails runner script/import/searchkick_restore.rb
```

Default input directory: `tmp/export/` (typical output from export, but any compatible JSON bundle works).
