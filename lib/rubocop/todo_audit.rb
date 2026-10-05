# frozen_string_literal: true

module RuboCop
  # Audits `.rubocop_todo.yml` for `Exclude` entries that are no longer
  # needed: files a cop would not flag anymore, or files that no longer
  # exist. Used by the `--report-unused-todo-entries` and `--prune-todo`
  # options.
  # @api private
  class TodoAudit
    Entry = Struct.new(:cop_name, :path)

    def initialize(config_store, options)
      @config_store = config_store
      @options = options
    end

    # @return [Array<Entry>, nil] the unused entries, or `nil` when there is
    #   no todo file to audit
    def unused_entries
      return nil unless todo_path

      todo_exclude_entries.reject { |entry| offense_count(entry).positive? }
    end

    # @return [Integer] the number of offenses the entry's cop still reports
    #   in the entry's file once the todo exclusions are subtracted
    def offense_count(entry)
      offense_counts.dig(absolute(entry.path), entry.cop_name) || 0
    end

    def todo_file
      CLI::Command::AutoGenerateConfig::AUTO_GENERATED_FILE
    end

    private

    def offense_counts
      @offense_counts ||= offense_counts_without_todo(todo_exclude_entries)
    end

    def todo_path
      return @todo_path if defined?(@todo_path)

      path = File.expand_path(todo_file)
      @todo_path = File.exist?(path) ? path : nil
    end

    def todo_exclude_entries
      @todo_exclude_entries ||= parse_todo_exclude_entries
    end

    def parse_todo_exclude_entries
      yaml = YAML.safe_load_file(todo_path, permitted_classes: [Regexp, Symbol], aliases: true)
      return [] unless yaml.is_a?(Hash)

      yaml.flat_map do |cop_name, cop_config|
        next [] unless auditable_cop?(cop_name, cop_config)

        cop_config['Exclude'].grep(String).map { |path| Entry.new(cop_name, path) }
      end
    end

    # Only registered cops with an `Exclude` list can be audited - for an
    # unknown cop (e.g. from an extension that is not loaded in this run)
    # the absence of offenses proves nothing.
    def auditable_cop?(cop_name, cop_config)
      cop_name.include?('/') &&
        cop_config.is_a?(Hash) &&
        cop_config['Exclude'].is_a?(Array) &&
        Cop::Registry.global.contains_cop_matching?([cop_name])
    end

    # Inspects every file the todo entries mention, with the todo exclusions
    # subtracted from the configuration, and returns the number of offenses
    # per cop name, keyed by absolute file path.
    def offense_counts_without_todo(entries)
      files = entries.map { |entry| absolute(entry.path) }.uniq.select { |file| File.file?(file) }

      files.to_h do |file|
        offenses = inspect_file(file, entries)
        [file, offenses.map(&:cop_name).tally]
      end
    end

    def inspect_file(file, entries)
      config = audit_config(@config_store.for_file(file), entries)
      team = Cop::Team.mobilize(Cop::Registry.global, config, @options.merge(autocorrect: false))

      processed_source = ProcessedSource.from_file(
        file, config.target_ruby_version, parser_engine: config.parser_engine
      )
      processed_source.config = config
      processed_source.registry = Cop::Registry.global

      team.investigate(processed_source).offenses.reject(&:disabled?)
    end

    # A copy of the configuration with the todo exclusions removed for the
    # audited cops, so their offenses in the listed files become visible.
    def audit_config(config, entries)
      hash = config.to_hash.dup

      entries.group_by(&:cop_name).each do |cop_name, cop_entries|
        cop_config = hash[cop_name]
        next unless cop_config.is_a?(Hash) && cop_config['Exclude'].is_a?(Array)

        hash[cop_name] = subtract_excludes(cop_config, cop_entries)
      end

      Config.create(hash, config.loaded_path, check: false)
    end

    def subtract_excludes(cop_config, cop_entries)
      removals = cop_entries.map { |entry| absolute(entry.path) }
      cop_config.merge('Exclude' => cop_config['Exclude'] - removals)
    end

    def absolute(path)
      File.expand_path(path, File.dirname(todo_path))
    end
  end
end
