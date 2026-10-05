# frozen_string_literal: true

module RuboCop
  class CLI
    module Command
      # Removes the `Exclude` entries of `.rubocop_todo.yml` that
      # `--report-unused-todo-entries` would report. Nothing is ever added
      # to the todo file; use `--regenerate-todo` for that.
      # @api private
      class PruneTodo < Base
        self.command_name = :prune_todo

        def run
          raise OptionArgumentError, '--prune-todo does not accept paths.' if @paths.any?

          audit = TodoAudit.new(@config_store, @options)
          unused = audit.unused_entries
          return no_todo_file(audit.todo_file) if unused.nil?

          unused = unused.reject { |entry| unknown?(audit, entry) }
          return nothing_to_prune(audit.todo_file) if unused.empty?

          prune(audit, unused)
        end

        private

        def prune(audit, unused)
          todo_file = audit.todo_file
          pruned = TodoPruner.new(File.read(todo_file, encoding: Encoding::UTF_8))
                             .prune(unused) { |entry| audit.offense_count(entry) }
          return cannot_prune(todo_file, unused) unless pruned

          File.write(todo_file, pruned)
          print_entries("Removed #{entries(unused.size)} from `#{todo_file}`:", unused)
          STATUS_SUCCESS
        end

        # Glob exclusions are not resolved to files by the audit yet (see
        # https://github.com/rubocop/rubocop/issues/15570), and a file that
        # cannot be parsed has no offenses other than the syntax error, so
        # neither tells whether the entry is still needed.
        def unknown?(audit, entry)
          PathUtil.glob?(entry.path) ||
            audit.offense_count(TodoAudit::Entry.new('Lint/Syntax', entry.path)).positive?
        end

        def no_todo_file(todo_file)
          warn Rainbow("No `#{todo_file}` found; nothing to prune.").yellow
          STATUS_SUCCESS
        end

        def nothing_to_prune(todo_file)
          puts "No unused todo entries found in `#{todo_file}`."
          STATUS_SUCCESS
        end

        def cannot_prune(todo_file, unused)
          warn Rainbow("Could not prune `#{todo_file}` safely; " \
                       "remove #{entries(unused.size)} by hand:").red
          unused.each { |entry| warn "  #{entry.cop_name}: #{entry.path}" }
          STATUS_ERROR
        end

        def print_entries(message, unused)
          puts message
          unused.each { |entry| puts "  #{entry.cop_name}: #{entry.path}" }
        end

        def entries(count)
          count == 1 ? '1 unused todo entry' : "#{count} unused todo entries"
        end
      end
    end
  end
end
