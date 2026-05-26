# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'import_config'

module Import
  module Helpers
    module_function

    def load_json_array(path)
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path))
      raise ArgumentError, "Expected array in #{path}" unless data.is_a?(Array)

      data
    end

    def postgres_connection?(conn)
      conn.adapter_name.match?(/postgresql/i)
    end

    def coerce_row(model_class, raw)
      row = raw.stringify_keys
      model_class.column_names.each_with_object({}) do |name, h|
        h[name] = coerce_column(model_class.columns_hash[name], row[name])
      end
    end

    def coerce_column(col, v)
      return nil if v.nil?

      if col.try(:array)
        return v if v.is_a?(Array)
        if v.is_a?(String) && v.lstrip.start_with?('[')
          begin
            return JSON.parse(v)
          rescue JSON::ParserError
            return [v].compact
          end
        end

        return Array.wrap(v).compact
      end

      case col.type
      when :datetime, :timestamp
        Time.zone.parse(v.to_s)
      when :date
        Date.parse(v.to_s)
      when :integer, :bigint
        v.to_i
      when :float
        v.to_f
      when :decimal
        BigDecimal(v.to_s)
      when :boolean
        ActiveModel::Type::Boolean.new.cast(v)
      else
        v
      end
    end

    def import_table!(model_class, rows, skip_existing:, stats:)
      path_label = model_class.table_name
      unless rows.is_a?(Array) && rows.any?
        stats[path_label] = { 'inserted' => 0, 'skipped_existing' => 0, 'note' => 'no rows' }
        return
      end

      conn = model_class.connection
      batch_size = Import::Config::BATCH_SIZE
      ids = rows.filter_map { |r| r['id']&.to_i }
      existing = if skip_existing && ids.any?
                   model_class.unscoped.where(id: ids).pluck(:id).to_set
                 else
                   Set.new
                 end

      inserted = 0
      skipped = 0

      model_class.transaction do
        batch = []
        flush = lambda do
          return if batch.empty?

          model_class.insert_all(batch)
          inserted += batch.size
          batch.clear
        end

        rows.each do |raw|
          eid = raw['id']&.to_i
          if skip_existing && eid && existing.include?(eid)
            skipped += 1
            next
          end

          batch << coerce_row(model_class, raw)
          flush.call if batch.size >= batch_size
        end
        flush.call
      end

      reset_pk_sequence_if_pg!(model_class, conn)

      stats[path_label] = { 'inserted' => inserted, 'skipped_existing' => skipped }
    rescue StandardError => e
      stats[path_label] = { 'error' => "#{e.class}: #{e.message}" }
      raise
    end

    def reset_pk_sequence_if_pg!(model_class, conn = model_class.connection)
      return unless postgres_connection?(conn)

      conn.reset_pk_sequence!(model_class.table_name)
    rescue StandardError => e
      warn "[import] reset_pk_sequence! #{model_class.table_name}: #{e.message}"
    end

    def join_table_insert_model(table_name)
      @join_table_insert_models ||= {}
      @join_table_insert_models[table_name] ||= Class.new(ApplicationRecord) do
        self.table_name = table_name
        self.record_timestamps = false
      end
    end

    def join_row_attrs(spec, raw)
      raw = raw.stringify_keys
      spec[:columns].each_with_object({}) do |col, h|
        v = raw[col]
        h[col] =
          if v.nil?
            nil
          elsif col.end_with?('_at')
            Time.zone.parse(v.to_s)
          else
            v.to_i
          end
      end
    end

    def import_story_join_table!(spec:, input_dir:, stats:, story_ids:, purge_for_story_ids:)
      file_key = spec[:file]
      path = Pathname.new(input_dir).join("#{file_key}.json")
      unless File.file?(path)
        stats[file_key] = { 'skipped' => true, 'reason' => 'file missing' }
        return
      end

      rows = JSON.parse(File.read(path))
      rows = [] unless rows.is_a?(Array)
      if rows.empty?
        stats[file_key] = { 'inserted' => 0, 'note' => 'empty file' }
        return
      end

      model = join_table_insert_model(spec[:table])
      attrs_list = rows.map { |r| join_row_attrs(spec, r) }

      ActiveRecord::Base.transaction do
        if purge_for_story_ids && story_ids.any? && spec[:columns].include?('story_id')
          ActiveRecord::Base.connection.exec_delete(
            ActiveRecord::Base.sanitize_sql_array(
              ["DELETE FROM #{spec[:table]} WHERE story_id IN (?)", story_ids]
            ),
            "import purge #{spec[:table]}"
          )
        end

        attrs_list.each_slice(Import::Config::BATCH_SIZE) do |slice|
          model.insert_all(slice)
        end
      end

      stats[file_key] = { 'inserted' => attrs_list.size, 'purged_first' => purge_for_story_ids && story_ids.any? }
    rescue StandardError => e
      stats[file_key] = { 'error' => "#{e.class}: #{e.message}" }
      raise
    end

    def import_story_join_tables!(input_dir, stats:)
      story_rows = load_json_array(Pathname.new(input_dir).join('stories.json'))
      story_ids = story_rows.map { |r| r['id'] }.compact.uniq
      purge = Import::Config::IMPORT_PURGE_AUTHORS_STORIES

      Import::Config::STORY_JOIN_TABLE_IMPORTS.each do |spec|
        puts "[import] #{spec[:file]} (join)"
        import_story_join_table!(
          spec: spec,
          input_dir: input_dir,
          stats: stats,
          story_ids: story_ids,
          purge_for_story_ids: purge
        )
      end
    end

    def mirror_bundle_assets!(input_dir)
      source = Pathname.new(input_dir).join('assets')
      return { 'mirrored' => false } unless source.directory?

      fog_dir = Settings.fog.directory.to_s.sub(%r{\A/}, '')
      target = Rails.root.join('public', fog_dir)
      FileUtils.mkdir_p(target)
      Dir.each_child(source) do |name|
        FileUtils.cp_r(source.join(name), target.join(name))
      end
      { 'mirrored' => true, 'from' => source.to_s, 'to' => target.to_s }
    end

    def log_skipped_bundle_tables(input_dir)
      all_tables = Import::Config.table_names_in_bundle(input_dir)
      importable = Import::Config.import_model_classes(input_dir)
      imported_tables = importable.map(&:table_name).to_set

      join_files = Import::Config::STORY_JOIN_TABLE_IMPORTS.map { |s| s[:file] }.to_set

      all_tables.each do |table|
        next if imported_tables.include?(table)
        next if join_files.include?(table)

        model = Import::Config.model_for_table(table)
        reason = if model.nil?
                   'no ActiveRecord model'
                 elsif Import::Config.database_view?(model)
                   'database view (not insertable)'
                 else
                   'skipped'
                 end
        warn "[import] skip #{table}.json (#{reason})"
      end
    end

    def run_import!(input_dir:, skip_existing:, mirror_assets:)
      input_dir = Pathname.new(input_dir)
      report = {
        'input_dir' => input_dir.to_s,
        'started_at' => Time.now.utc.iso8601,
        'tables' => {}
      }
      stats = report['tables']

      log_skipped_bundle_tables(input_dir)
      models = Import::Config.import_model_classes(input_dir)
      puts "[import] #{models.size} table(s) to import from #{input_dir}"

      Searchkick.callbacks(false) do
        models.each do |model_class|
          file_path = input_dir.join("#{model_class.table_name}.json")
          rows = load_json_array(file_path)
          if rows.empty?
            stats[model_class.table_name] = { 'inserted' => 0, 'skipped_existing' => 0, 'note' => 'empty file' }
            next
          end

          puts "[import] #{model_class.name} (#{rows.size} rows)"
          import_table!(model_class, rows, skip_existing: skip_existing, stats: stats)
        end

        import_story_join_tables!(input_dir, stats: stats)
      end

      report['assets'] = mirror_assets ? mirror_bundle_assets!(input_dir) : { 'mirrored' => false }

      report['finished_at'] = Time.now.utc.iso8601
      FileUtils.mkdir_p(Import::Config::REPORT_PATH.dirname)
      File.write(Import::Config::REPORT_PATH, JSON.pretty_generate(report))
      puts "[import] report → #{Import::Config::REPORT_PATH}"
      report
    end
  end
end
