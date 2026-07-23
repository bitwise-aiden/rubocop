# frozen_string_literal: true

module RuboCop
  class CLI
    module Command
      # Re-checks the `Exclude` entries of the auto-generated TODO
      # configuration file and deletes the ones that no longer have offenses.
      #
      # Only the (cop, file) pairs recorded in the TODO file are inspected,
      # and only the cops listed for a file are run on it, so pruning is much
      # cheaper than regenerating the TODO file. Nothing is ever added:
      # new offenses, generated `Max`-style parameters, `EnforcedStyle`
      # settings and `Enabled: false` entries are left exactly as they are.
      # @api private
      class PruneTodo < Base
        self.command_name = :prune_todo

        TODO_FILE = AutoGenerateConfig::AUTO_GENERATED_FILE

        def run
          if @paths.any?
            raise OptionArgumentError, '--prune-todo cannot be combined with path arguments.'
          end
          unless File.exist?(TODO_FILE)
            raise Error, "No #{TODO_FILE} found. Generate one with --auto-gen-config first."
          end

          @source = File.read(TODO_FILE, encoding: Encoding::UTF_8)
          @pruner = TodoPruner.new(@source)
          prune(checkable_matrix)
        end

        private

        def prune(matrix)
          if matrix.empty?
            puts "Nothing to prune in #{TODO_FILE}."
            return STATUS_SUCCESS
          end

          status = inspect_matrix(matrix)
          return status unless status == STATUS_SUCCESS

          rewrite_todo_file(matrix)
        end

        # The subset of the TODO file's cop => files map that we can actually
        # check: the cop must be known to the registry (so that, for example,
        # an entry for a cop from a temporarily unavailable extension is not
        # pruned away), and may be narrowed further with `--only`.
        def checkable_matrix
          matrix = @pruner.matrix
          matrix.select! { |cop_name, _files| only_cops.include?(cop_name) } if only_cops

          unknown, known = matrix.partition do |cop_name, _files|
            Cop::Registry.global.find_by_cop_name(cop_name).nil?
          end
          warn_unknown_cops(unknown)

          known.to_h { |cop_name, files| [cop_name, expand_paths(files)] }
        end

        def warn_unknown_cops(unknown)
          unknown.each do |(cop_name, _files)|
            warn Rainbow("Keeping entry for unknown cop #{cop_name}.").yellow
          end
        end

        def only_cops
          return unless @options[:only]

          @options[:only].map { |cop| Cop::Registry.qualified_cop_name(cop, '--only option') }
        end

        def expand_paths(files)
          files.to_set { |file| File.expand_path(file) }
        end

        # Runs the (cop, file) matrix with the TODO file temporarily emptied,
        # so that its own `Exclude` entries do not hide the offenses we are
        # looking for. The original file is always restored; the pruned
        # version is written afterwards by `rewrite_todo_file`.
        def inspect_matrix(matrix)
          target_files = matrix.values.reduce(:|).select { |file| File.exist?(file) }.sort
          puts Rainbow("Checking #{target_files.size} file(s) across " \
                       "#{matrix.size} cop(s) listed in #{TODO_FILE}.").yellow

          prepare_options(matrix)
          File.write(TODO_FILE, '')
          run_matrix_inspection(target_files)
        ensure
          File.write(TODO_FILE, @source)
        end

        def run_matrix_inspection(target_files)
          config_store = ConfigStore.new
          config_store.apply_options!(@options)

          runner = Runner.new(@options, config_store)
          runner.run(target_files)
          runner.aborting? ? STATUS_INTERRUPTED : STATUS_SUCCESS
        end

        def prepare_options(matrix)
          @options[:only] = [*matrix.keys.sort, 'Lint/Syntax']
          @options[:prune_todo_matrix] = matrix
          # A file that the configuration excludes can never have offenses
          # reported, so treat it like any other file without offenses.
          @options[:force_exclusion] = true
          @options[:formatters] ||= [['autogenconf', nil]]
          @options[:formatters] += [[Formatter::PruneTodoFormatter, nil]]
        end

        def rewrite_todo_file(matrix)
          @offense_counts = Formatter::PruneTodoFormatter.offense_counts
          @unparsable_files = Formatter::PruneTodoFormatter.unparsable_files

          result = @pruner.prune(checked_cops: matrix.keys.to_set,
                                 keep: method(:keep_item?), count: method(:item_count))

          write_pruned_file(result)
        end

        def write_pruned_file(result)
          unless valid_yaml?(result.output)
            warn Rainbow("Pruning would leave #{TODO_FILE} unparsable; " \
                         'leaving it unchanged.').red
            return STATUS_ERROR
          end

          File.write(TODO_FILE, result.output)
          puts "Removed #{result.removed_items} exclusion(s) and #{result.removed_entries} " \
               "cop entry(ies) from #{TODO_FILE}."
          STATUS_SUCCESS
        end

        def keep_item?(cop_name, path)
          absolute = File.expand_path(path)
          @offense_counts[cop_name][absolute].positive? || @unparsable_files.include?(absolute)
        end

        # An unparsable file's offense count is unknown, so the
        # `# Offense count` comment cannot be updated reliably.
        def item_count(cop_name, path)
          absolute = File.expand_path(path)
          @offense_counts[cop_name][absolute] unless @unparsable_files.include?(absolute)
        end

        def valid_yaml?(source)
          # A fully pruned file that only contains comments parses as nil,
          # which is fine; only a parse error makes the result invalid.
          YAML.safe_load(source, permitted_classes: [Regexp, Symbol], aliases: true)
          true
        rescue StandardError
          false
        end
      end
    end
  end
end
