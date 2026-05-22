# frozen_string_literal: true

# PHASE 4 — Searchkick-safe bulk reindex for imported export models.
#
# Reads ids from the same JSON bundle as PHASE 3 and runs Searchkick’s relation
# import with callbacks disabled, in batches — no per-record `after_commit` async
# jobs from this path.
#
# Prerequisites:
#   - Elasticsearch reachable (Searchkick.client).
#   - Rows already present in DB (after import_all.rb).
#
# Usage (app root):
#   bundle exec rails runner script/export/searchkick_restore.rb
#
# Environment:
#   IMPORT_INPUT_DIR=/path/to/bundle     # default tmp/export
#   SEARCHKICK_RESTORE_BATCH=300        # records per Searchkick batch
#   SEARCHKICK_RESTORE_REFRESH=0        # skip index refresh after each model
#   SEARCHKICK_ONLY=Language,Story      # optional comma-separated model names

require File.expand_path('../../config/environment', __dir__)
require_relative 'export_config'

input = Export::Config::IMPORT_INPUT_DIR
batch = Export::Config::SEARCHKICK_RESTORE_BATCH
per_model_refresh = Export::Config::SEARCHKICK_RESTORE_REFRESH

only = ENV['SEARCHKICK_ONLY'].to_s.split(',').map(&:strip).reject(&:blank?)
if only.any?
  klass_by_name = Export::Config.searchkick_restorable_classes.index_by(&:name)
  bad = only.reject { |n| klass_by_name.key?(n) }
  raise ArgumentError, "SEARCHKICK_ONLY unknown: #{bad.join(', ')}" if bad.any?

  classes = only.map { |n| klass_by_name[n] }
else
  classes = Export::Config.searchkick_restorable_classes
end

Searchkick.callbacks(false) do
  classes.each do |klass|
    path = input.join("#{klass.table_name}.json")
    unless File.file?(path)
      warn "[searchkick_restore] skip #{klass.name}: missing #{path}"
      next
    end

    ids = JSON.parse(File.read(path)).filter_map { |r| r['id'] }.uniq
    if ids.empty?
      warn "[searchkick_restore] skip #{klass.name}: no ids in file"
      next
    end

    puts "[searchkick_restore] #{klass.name}: #{ids.size} ids, batch #{batch}"
    klass.unscoped.where(id: ids).in_batches(of: batch) do |rel|
      klass.searchkick_index.reindex(rel, mode: :inline)
    end
    klass.searchkick_index.refresh if per_model_refresh
    puts "[searchkick_restore] #{klass.name}: batches done"
  end
end

puts '[searchkick_restore] complete'
