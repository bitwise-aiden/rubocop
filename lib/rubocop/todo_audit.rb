# frozen_string_literal: true

require 'parallel'

module RuboCop
  # Audits `.rubocop_todo.yml` for `Exclude` entries that are no longer
  # needed: files a cop would not flag anymore, or files that no longer
  # exist. Used by the `--report-unused-todo-entries` option.
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

      entries = todo_exclude_entries
      return [] if entries.empty?

      offending_cops = offending_cops_without_todo(entries)
      entries.reject { |entry| offending_cops[absolute(entry.path)]&.include?(entry.cop_name) }
    end

    def todo_file
      CLI::Command::AutoGenerateConfig::AUTO_GENERATED_FILE
    end

    private

    def todo_path
      return @todo_path if defined?(@todo_path)

      path = File.expand_path(todo_file)
      @todo_path = File.exist?(path) ? path : nil
    end

    def todo_exclude_entries
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
    # subtracted from the configuration, and returns the names of the cops
    # that still report offenses, keyed by absolute file path.
    #
    # Each file is inspected only with the cops that have an entry for it:
    # the offenses of a cop do not depend on which other cops run, so the
    # other cops cannot change whether an entry is still needed.
    def offending_cops_without_todo(entries)
      cop_names_by_file = cop_names_by_file(entries)
      files = cop_names_by_file.keys.select { |file| File.file?(file) }

      offending_cops = map_files(files) do |file|
        inspect_file(file, cop_names_by_file[file], entries).map(&:cop_name).uniq
      end
      files.zip(offending_cops).to_h { |file, cop_names| [file, cop_names.to_set] }
    end

    def cop_names_by_file(entries)
      entries.group_by { |entry| absolute(entry.path) }
             .transform_values { |file_entries| file_entries.map(&:cop_name).uniq.sort }
    end

    # With `--parallel`, the files are inspected in worker processes.
    def map_files(files, &block)
      if @options[:parallel] && files.size > 1
        Parallel.map(files, &block)
      else
        files.map(&block)
      end
    end

    def inspect_file(file, cop_names, entries)
      config = audit_config(@config_store.for_file(file), entries)
      team = Cop::Team.mobilize(registry_for(cop_names), config, @options.merge(autocorrect: false))

      processed_source = ProcessedSource.from_file(
        file, config.target_ruby_version, parser_engine: config.parser_engine
      )
      processed_source.config = config
      processed_source.registry = Cop::Registry.global

      team.investigate(processed_source).offenses.reject(&:disabled?)
    end

    # The cops with the given names, in a registry that is shared by all the
    # files with the same cops so that their enabled cops are found only once
    # for each configuration.
    def registry_for(cop_names)
      @registries ||= {}
      @registries[cop_names] ||= begin
        registry = Cop::Registry.global
        registry.filter_by_badge(registry.options) { |badge| cop_names.include?(badge.to_s) }
      end
    end

    # A copy of the configuration with the todo exclusions removed for the
    # audited cops, so their offenses in the listed files become visible.
    # Files that share a configuration share its copy.
    def audit_config(config, entries)
      @audit_configs ||= {}.compare_by_identity
      @audit_configs[config] ||= build_audit_config(config, entries)
    end

    def build_audit_config(config, entries)
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
