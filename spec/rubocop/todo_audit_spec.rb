# frozen_string_literal: true

RSpec.describe RuboCop::TodoAudit, :isolated_environment do
  include FileHelper

  subject(:audit) { described_class.new(config_store, {}) }

  let(:config_store) { RuboCop::ConfigStore.new }
  let(:teams) { [] }
  let(:configs) { [] }

  before do
    create_file('.rubocop.yml', <<~YAML)
      inherit_from: .rubocop_todo.yml
    YAML
    create_file('.rubocop_todo.yml', <<~YAML)
      Style/ClassVars:
        Exclude:
          - 'clean.rb'
          - 'offending.rb'
      Style/StringLiterals:
        Exclude:
          - 'offending.rb'
    YAML
    create_file('clean.rb', <<~RUBY)
      # frozen_string_literal: true

      puts 1
    RUBY
    create_file('offending.rb', <<~RUBY)
      # frozen_string_literal: true

      @@bad = "bad"
    RUBY

    allow(RuboCop::Cop::Team).to receive(:mobilize).and_wrap_original do |method, *args|
      configs << args[1]
      method.call(*args).tap { |team| teams << team }
    end
  end

  it 'reports the entries whose cop no longer flags the file' do
    expect(audit.unused_entries).to eq([described_class::Entry.new('Style/ClassVars', 'clean.rb')])
  end

  it 'inspects each file only with the cops that have entries for it' do
    audit.unused_entries

    expect(teams.map { |team| team.cops.map(&:cop_name) })
      .to contain_exactly(['Style/ClassVars'], ['Style/ClassVars', 'Style/StringLiterals'])
  end

  it 'builds the audit configuration once for files that share a configuration' do
    audit.unused_entries

    expect(configs.size).to eq(2)
    expect(configs.uniq(&:object_id).size).to eq(1)
  end
end
