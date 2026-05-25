# frozen_string_literal: true

# Import-only configuration. Does not load script/export/*.
#
# Table list comes from JSON files in INPUT_DIR (any bundle layout), not from
# Export::Config.export_model_classes.

module Import
  module Config
    INPUT_DIR =
      if ENV['IMPORT_INPUT_DIR'].present?
        Pathname.new(ENV['IMPORT_INPUT_DIR'])
      else
        Rails.root.join('tmp/export')
      end

    REPORT_PATH =
      if ENV['IMPORT_REPORT_PATH'].present?
        Pathname.new(ENV['IMPORT_REPORT_PATH'])
      else
        INPUT_DIR.join('import_report.json')
      end

    BATCH_SIZE = (ENV['IMPORT_BATCH_SIZE']&.to_i&.nonzero? || 500)

    IMPORT_SKIP_EXISTING = !%w[0 false no off].include?(ENV.fetch('IMPORT_SKIP_EXISTING', 'true').to_s.downcase)
    IMPORT_MIRROR_ASSETS = %w[1 true yes on].include?(ENV['IMPORT_MIRROR_ASSETS'].to_s.downcase)
    IMPORT_PURGE_AUTHORS_STORIES = !%w[0 false no off].include?(ENV.fetch('IMPORT_PURGE_AUTHORS_STORIES', 'true').to_s.downcase)

    # JSON files that are not table dumps (still allowed in the bundle dir).
    NON_TABLE_JSON = %w[
      paperclip_manifest
      asset_sync_report
      import_report
    ].freeze

    # Prefer importing core story tables first when those files exist.
    PREFERRED_TABLE_ORDER = %w[
      languages
      organizations
      users
      illustrations
      illustration_crops
      stories
      pages
      boxes
    ].freeze

    SEARCHKICK_RESTORE_BATCH = (ENV['SEARCHKICK_RESTORE_BATCH']&.to_i&.nonzero? || 200)
    SEARCHKICK_RESTORE_REFRESH = !%w[0 false no off].include?(ENV.fetch('SEARCHKICK_RESTORE_REFRESH', 'true').to_s.downcase)

    def self.eager_load_app_models!
      return if @eager_loaded

      Rails.application.eager_load! unless Rails.application.config.eager_load
      @eager_loaded = true
    end

    def self.database_view?(model_class)
      conn = model_class.connection
      return false unless conn.adapter_name.match?(/postgresql/i)

      sql = ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            SELECT c.relkind
            FROM pg_class c
            INNER JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = ?
              AND n.nspname = ANY (current_schemas(false))
            LIMIT 1
          SQL
          model_class.table_name
        ]
      )
      conn.select_value(sql) == 'v'
    rescue StandardError
      false
    end

    # Basenames of table JSON files in the bundle (e.g. "stories" for stories.json).
    def self.table_names_in_bundle(input_dir = INPUT_DIR)
      dir = Pathname.new(input_dir)
      return [] unless dir.directory?

      dir.children
        .select { |p| p.file? && p.extname == '.json' }
        .map { |p| p.basename('.json').to_s }
        .reject { |name| NON_TABLE_JSON.include?(name) || name == 'authors_stories' }
    end

    def self.model_for_table(table_name)
      eager_load_app_models!
      @model_by_table ||= {}
      return @model_by_table[table_name] if @model_by_table.key?(table_name)

      model = ApplicationRecord.descendants.find do |m|
        !m.abstract_class? &&
          m < ApplicationRecord &&
          m.table_exists? &&
          m.primary_key.present? &&
          m.base_class == m &&
          m.table_name == table_name
      end
      @model_by_table[table_name] = model
    end

    # Resolve import order from bundle filenames + preferred story tables first.
    def self.import_model_classes(input_dir = INPUT_DIR)
      eager_load_app_models!
      ordered_tables = table_names_in_bundle(input_dir).sort_by do |table|
        pref = PREFERRED_TABLE_ORDER.index(table)
        [pref.nil? ? 1 : 0, pref || table, table]
      end

      ordered_tables.filter_map do |table|
        model = model_for_table(table)
        next nil if model.nil?
        next nil if database_view?(model)

        model
      end
    end

    def self.searchkick_restorable_classes(input_dir = INPUT_DIR)
      import_model_classes(input_dir).select { |m| m.respond_to?(:searchkick_index) }
    end
  end
end
