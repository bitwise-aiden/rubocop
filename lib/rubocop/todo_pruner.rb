# frozen_string_literal: true

module RuboCop
  # Parses an auto-generated TODO configuration file into per-cop entries and
  # rewrites it with pruned `Exclude` lists, preserving all other content
  # byte-for-byte. Only plain, single-file `Exclude` items are candidates for
  # pruning; regexps, globs, and anything else that cannot be verified against
  # a single file on disk is always kept. Entries for cops that were not
  # checked are left untouched.
  # @api private
  class TodoPruner
    COP_NAME_PATTERN = %r{\A(?:[A-Z][A-Za-z0-9]*(?:/[A-Z][A-Za-z0-9]*)+):[ \t]*(?:#.*)?\z}.freeze
    EXCLUDE_KEY_PATTERN = /\A {2}Exclude:[ \t]*\z/.freeze
    ITEM_PATTERN = /\A {4}- (?<item>.*?)[ \t]*\z/.freeze
    QUOTED_FILE_PATTERN = /\A(?:'(?<spath>[^']+)'|"(?<dpath>[^"\\#]+)")\z/.freeze
    GLOB_PATTERN = /[*?\[\]{}]/.freeze
    OFFENSE_COUNT_PATTERN = /\A# Offense count: \d+[ \t]*\z/.freeze
    INDENTED_LINE_PATTERN = /\A[ \t]+\S/.freeze

    # A verifiable, single-file `Exclude` list item.
    Item = Struct.new(:line_index, :path)

    # A single cop entry in the TODO file: its comment block, header line,
    # body lines, and any `Exclude` items found in the body.
    Entry = Struct.new(:cop_name, :comment_start, :header_index, :end_index,
                       :exclude_index, :items, :unverifiable_item_count,
                       keyword_init: true) do
      def body_range
        (header_index + 1)...end_index
      end
    end

    Result = Struct.new(:output, :removed_items, :removed_entries, keyword_init: true)

    attr_reader :entries

    def initialize(source)
      @source = source
      @lines = source.lines
      @chomped = @lines.map(&:chomp)
      @entries = parse
    end

    # Map of cop name to the relative paths of all verifiable `Exclude` items.
    def matrix
      matrix = Hash.new { |hash, key| hash[key] = [] }
      @entries.each do |entry|
        entry.items.each { |item| matrix[entry.cop_name] << item.path }
      end
      matrix.each_value(&:uniq!)
      matrix
    end

    # Rewrites the TODO source, removing `Exclude` items for which
    # `keep.call(cop_name, path)` is false, and updating `# Offense count`
    # comments using `count.call(cop_name, path)` where this can be done
    # reliably. Only entries whose cop is in `checked_cops` are modified.
    def prune(checked_cops:, keep:, count:)
      @dropped = Set.new
      @replacements = {}
      @removed_items = 0
      @removed_entries = 0

      @entries.each do |entry|
        next unless checked_cops.include?(entry.cop_name) && !entry.items.empty?

        prune_entry(entry, keep, count)
      end

      Result.new(output: assemble_output,
                 removed_items: @removed_items, removed_entries: @removed_entries)
    end

    private

    def parse
      entries = []
      index = 0
      while index < @lines.size
        unless COP_NAME_PATTERN.match?(@chomped[index])
          index += 1
          next
        end

        entry = parse_entry(index)
        entries << entry
        index = entry.end_index
      end
      entries
    end

    def parse_entry(header_index)
      comment_start = header_index
      comment_start -= 1 while comment_start.positive? && @lines[comment_start - 1].start_with?('#')

      end_index = header_index + 1
      end_index += 1 while end_index < @lines.size &&
                           INDENTED_LINE_PATTERN.match?(@chomped[end_index])

      entry = Entry.new(cop_name: @lines[header_index][/\A[^:]+/], comment_start: comment_start,
                        header_index: header_index, end_index: end_index,
                        exclude_index: nil, items: [], unverifiable_item_count: 0)
      parse_exclude_items(entry)
      entry
    end

    def parse_exclude_items(entry)
      index = entry.body_range.find do |line_index|
        EXCLUDE_KEY_PATTERN.match?(@chomped[line_index])
      end
      return unless index

      entry.exclude_index = index
      ((index + 1)...entry.end_index).each do |item_index|
        item = ITEM_PATTERN.match(@chomped[item_index])
        break unless item

        add_item(entry, item_index, item[:item])
      end
    end

    def add_item(entry, line_index, text)
      if (path = verifiable_path(text))
        entry.items << Item.new(line_index, path)
      else
        entry.unverifiable_item_count += 1
      end
    end

    def verifiable_path(item)
      match = QUOTED_FILE_PATTERN.match(item)
      return unless match

      path = match[:spath] || match[:dpath]
      path unless GLOB_PATTERN.match?(path)
    end

    def prune_entry(entry, keep, count)
      kept, removed = entry.items.partition { |item| keep.call(entry.cop_name, item.path) }
      removed.each { |item| @dropped << item.line_index }
      @removed_items += removed.size
      return unless entry.unverifiable_item_count.zero?

      if kept.empty?
        drop_empty_entry(entry)
      else
        update_offense_count(entry, kept, count)
      end
    end

    # All items of the entry were removed; drop the `Exclude:` key, and if the
    # entry body is now empty, the whole entry including its comment block and
    # one adjacent separator blank line.
    def drop_empty_entry(entry)
      @dropped << entry.exclude_index
      return unless remaining_body_empty?(entry)

      drop_entire_entry(entry)
      @removed_entries += 1
    end

    def remaining_body_empty?(entry)
      entry.body_range.all? do |line_index|
        @dropped.include?(line_index) || @lines[line_index].strip.empty?
      end
    end

    def drop_entire_entry(entry)
      (entry.comment_start...entry.end_index).each { |line_index| @dropped << line_index }
      if blank_line?(entry.end_index)
        @dropped << entry.end_index
      elsif blank_line?(entry.comment_start - 1)
        @dropped << (entry.comment_start - 1)
      end
    end

    def update_offense_count(entry, kept, count)
      comment_index = (entry.comment_start...entry.header_index).find do |line_index|
        OFFENSE_COUNT_PATTERN.match?(@chomped[line_index])
      end
      return unless comment_index

      counts = kept.map { |item| count.call(entry.cop_name, item.path) }
      return if counts.any?(&:nil?)

      replacement = "# Offense count: #{counts.sum}\n"
      @replacements[comment_index] = replacement if replacement != @lines[comment_index]
    end

    def assemble_output
      @lines.each_with_index.map do |line, index|
        next if @dropped.include?(index)

        @replacements.fetch(index, line)
      end.join
    end

    def blank_line?(index)
      index >= 0 && index < @lines.size && @lines[index].strip.empty?
    end
  end
end
