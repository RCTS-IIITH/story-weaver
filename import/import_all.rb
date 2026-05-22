# frozen_string_literal: true

# PHASE 3 — Import a PHASE 1 JSON bundle (+ optional PHASE 2 `assets/` folder).
#
# Prerequisites:
#   - Database reachable; target env should be disposable (imports use fixed ids).
#   - Run after export: `export_all.rb` → optional `sync_assets.rb` → this script.
#
# Usage (app root):
#   bundle exec rails runner script/export/import_all.rb
#
# Environment:
#   IMPORT_INPUT_DIR=/path/to/bundle   # default: tmp/export
#   IMPORT_SKIP_EXISTING=false        # default: true — skip conflicting primary keys
#   IMPORT_MIRROR_ASSETS=1          # copy bundle assets/ → public/<fog.directory>/ (opt-in)
#   IMPORT_PURGE_AUTHORS_STORIES=0    # default: true — delete authors_stories for imported story ids first
#
# Then reindex Elasticsearch (PHASE 4):
#   bundle exec rails runner script/export/searchkick_restore.rb

require File.expand_path('../../config/environment', __dir__)
require_relative 'export_config'
require_relative 'import_helpers'

input = Export::Config::IMPORT_INPUT_DIR
skip_existing = Export::Config::IMPORT_SKIP_EXISTING
mirror = Export::Config::IMPORT_MIRROR_ASSETS

unless input.directory?
  warn "[import] Input directory missing: #{input}"
  exit 2
end

warn '[import] This writes rows with explicit ids and may conflict with FKs or unique indexes.'
warn '[import] Prefer an empty/seeded dev database or IMPORT_SKIP_EXISTING=true.'

Export::Import::Helpers.run_import!(
  input_dir: input,
  skip_existing: skip_existing,
  mirror_assets: mirror
)

puts '[import] Done. Next: bundle exec rails runner script/export/searchkick_restore.rb'
