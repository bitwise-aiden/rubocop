# frozen_string_literal: true

module RuboCop
  # Removes `Exclude` entries from the contents of an auto-generated
  # `.rubocop_todo.yml` and leaves every other line as it is. When the last
  # entry of a cop is removed, the cop's whole section (including its
  # comments) is removed too. Used by the `--prune-todo` option.
  #
  # The rewrite works on lines so that comments and formatting survive, and
  # the result is checked against the expected configuration before it is
  # returned: if the file is laid out in a way the line-based rewrite does
  # not understand, nothing is pruned.
  # @api private
  class TodoPruner
    COP_HEADER = %r{\A(?<cop_name>[A-Z]\w*(?:/[A-Z]\w*)+):[ \t]*(?:#.*)?\z}.freeze
    EXCLUDE_KEY = /\A {2}Exclude:[ \t]*\z/.freeze
    EXCLUDE_ITEM = /\A {4}- (?<value>.+?)[ \t]*\z/.freeze
    OFFENSE_COUNT = /\A# Offense count: \d+[ \t]*\z/.freeze
    INDENTED = /\A[ \t]+\S/.freeze
    YAML_OPTIONS = { permitted_classes: [Regexp, Symbol], aliases: true }.freeze

    Section = Struct.new(:cop_name, :comment_start, :header, :end, :exclude_key, :items)
    Item = Struct.new(:index, :value)

    def initialize(source)
      @source = source
      @lines = source.lines
      @chomped = @lines.map(&:chomp)
    end

    # @param entries [Array<TodoAudit::Entry>] the entries to remove
    # @yieldparam entry [TodoAudit::Entry] an entry that is kept in a section
    #   that loses other entries
    # @yieldreturn [Integer] the number of offenses the kept entry excludes,
    #   used to update the section's `# Offense count` comment
    # @return [String, nil] the pruned source, or `nil` when it cannot be
    #   pruned safely
    def prune(entries, &offense_count)
      removals = entries.group_by(&:cop_name).transform_values { |list| list.to_set(&:path) }
      @dropped = Set.new
      @replaced = {}
      @offense_count = offense_count

      sections.each do |section|
        paths = removals[section.cop_name]
        prune_section(section, paths) if paths
      end

      output = render
      output if load_yaml(output) == expected_config(removals)
    end

    private

    def sections
      index = 0
      result = []
      while index < @lines.size
        if (match = COP_HEADER.match(@chomped[index]))
          result << section_at(index, match[:cop_name])
          index = result.last.end
        else
          index += 1
        end
      end
      result
    end

    def section_at(header, cop_name)
      comment_start = header
      comment_start -= 1 while comment_start.positive? && comment?(comment_start - 1)
      section_end = header + 1
      section_end += 1 while indented?(section_end)

      section = Section.new(cop_name, comment_start, header, section_end, nil, [])
      section.exclude_key = body(section).find { |index| EXCLUDE_KEY.match?(@chomped[index]) }
      section.items = exclude_items(section) if section.exclude_key
      section
    end

    def exclude_items(section)
      ((section.exclude_key + 1)...section.end).each_with_object([]) do |index, items|
        match = EXCLUDE_ITEM.match(@chomped[index])
        break items unless match

        items << Item.new(index, scalar(match[:value]))
      end
    end

    def prune_section(section, paths)
      removed, kept = section.items.partition { |item| paths.include?(item.value) }
      return if removed.empty?

      @dropped.merge(removed.map(&:index))
      if kept.empty?
        drop_exclude_key(section)
      else
        update_offense_count(section, kept)
      end
    end

    # Drops the `Exclude:` line, and the whole section when nothing else is left in it.
    def drop_exclude_key(section)
      @dropped << section.exclude_key
      drop_section(section) if body(section).all? { |index| @dropped.include?(index) }
    end

    def body(section)
      (section.header + 1)...section.end
    end

    # Drops the section with its comments and the blank line that separates
    # it from the next section, or from the previous one at the end of the file.
    def drop_section(section)
      @dropped.merge(section.comment_start...section.end)
      if blank?(section.end)
        @dropped << section.end
      else
        previous = section.comment_start - 1
        previous -= 1 while @dropped.include?(previous)
        @dropped << previous if blank?(previous)
      end
    end

    def update_offense_count(section, kept)
      index = (section.comment_start...section.header).find do |line_index|
        OFFENSE_COUNT.match?(@chomped[line_index])
      end
      return unless index && @offense_count && kept.all? { |item| single_file?(item.value) }

      count = kept.sum { |item| @offense_count.call(TodoAudit::Entry.new(section.cop_name, item.value)) }
      @replaced[index] = "# Offense count: #{count}\n"
    end

    # A glob or a regexp can stand for several files, so the number of
    # offenses it excludes is not known.
    def single_file?(value)
      value.is_a?(String) && !PathUtil.glob?(value)
    end

    def render
      @lines.each_with_index.filter_map do |line, index|
        @replaced.fetch(index, line) unless @dropped.include?(index)
      end.join
    end

    def expected_config(removals)
      config = load_yaml(@source)
      removals.each do |cop_name, paths|
        cop_config = config[cop_name]
        next unless cop_config.is_a?(Hash) && cop_config['Exclude'].is_a?(Array)

        cop_config['Exclude'] -= paths.to_a
        cop_config.delete('Exclude') if cop_config['Exclude'].empty?
        config.delete(cop_name) if cop_config.empty?
      end
      config
    end

    def load_yaml(source)
      YAML.safe_load(source, **YAML_OPTIONS) || {}
    end

    def scalar(value)
      YAML.safe_load(value, **YAML_OPTIONS)
    rescue Psych::Exception
      nil
    end

    def indented?(index)
      index < @lines.size && INDENTED.match?(@chomped[index])
    end

    def comment?(index)
      @chomped[index].start_with?('#')
    end

    def blank?(index)
      index >= 0 && index < @lines.size && @chomped[index].strip.empty?
    end
  end
end
