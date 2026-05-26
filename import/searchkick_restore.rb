# frozen_string_literal: true

# Reindex Searchkick models that have a matching JSON file in the import bundle.
# Does not load script/export.
#
#   bundle exec rails runner script/import/searchkick_restore.rb

require File.expand_path('../../config/environment', __dir__)
require_relative 'import_config'

input = Import::Config::INPUT_DIR
batch = Import::Config::SEARCHKICK_RESTORE_BATCH
per_model_refresh = Import::Config::SEARCHKICK_RESTORE_REFRESH

only = ENV['SEARCHKICK_ONLY'].to_s.split(',').map(&:strip).reject(&:blank?)
classes = if only.any?
            by_name = Import::Config.searchkick_restorable_classes(input).index_by(&:name)
            bad = only.reject { |n| by_name.key?(n) }
            raise ArgumentError, "SEARCHKICK_ONLY unknown: #{bad.join(', ')}" if bad.any?

            only.map { |n| by_name[n] }
          else
            Import::Config.searchkick_restorable_classes(input)
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
  end
end

puts '[searchkick_restore] complete'
