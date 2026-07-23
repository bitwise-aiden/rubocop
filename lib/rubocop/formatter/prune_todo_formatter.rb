# frozen_string_literal: true

module RuboCop
  module Formatter
    # Collects per-file offense information for `--prune-todo`. The collected
    # state is stored on the class so that the `PruneTodo` command can read it
    # after the runner has finished, mirroring how `DisabledConfigFormatter`
    # communicates with `--auto-gen-config`.
    # @api private
    class PruneTodoFormatter < BaseFormatter
      class << self
        # Map of cop name to a map of absolute file path to offense count.
        attr_accessor :offense_counts

        # Absolute paths of files that could not be parsed. Their TODO
        # entries are kept, since the cops could not check them.
        attr_accessor :unparsable_files
      end

      def started(_target_files)
        self.class.offense_counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        self.class.unparsable_files = Set.new
      end

      def file_finished(file, offenses)
        offenses.each do |offense|
          self.class.unparsable_files << file if offense.cop_name == 'Lint/Syntax'
          self.class.offense_counts[offense.cop_name][file] += 1
        end
      end
    end
  end
end
