# frozen_string_literal: true

# List tables that would be imported from JSON files in INPUT_DIR.
#
#   bundle exec rails runner script/import/list_tables.rb

require File.expand_path('../../config/environment', __dir__)
require_relative 'import_config'

dir = Import::Config::INPUT_DIR
Import::Config.import_model_classes(dir).each { |m| puts "#{m.table_name}.json -> #{m.name}" }
warn "--- importable: #{Import::Config.import_model_classes(dir).size} from #{dir}"
