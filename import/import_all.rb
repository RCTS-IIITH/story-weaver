# frozen_string_literal: true

# Import JSON table dumps from a directory (default tmp/export).
# Does not require script/export — only JSON files on disk.
#
#   bundle exec rails runner script/import/import_all.rb
#
#   IMPORT_INPUT_DIR=/path/to/bundle bundle exec rails runner script/import/import_all.rb

require File.expand_path('../../config/environment', __dir__)
require_relative 'import_config'
require_relative 'import_helpers'

input = Import::Config::INPUT_DIR
skip_existing = Import::Config::IMPORT_SKIP_EXISTING
mirror = Import::Config::IMPORT_MIRROR_ASSETS

unless input.directory?
  warn "[import] Input directory missing: #{input}"
  exit 2
end

warn '[import] Writes rows with explicit ids; use a disposable DB or IMPORT_SKIP_EXISTING=true.'

Import::Helpers.run_import!(
  input_dir: input,
  skip_existing: skip_existing,
  mirror_assets: mirror
)

puts '[import] Done. Optional: bundle exec rails runner script/import/searchkick_restore.rb'
