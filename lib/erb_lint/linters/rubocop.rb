# frozen_string_literal: true

require 'better_html'
require 'rubocop'
require 'tempfile'
require 'erb_lint/utils/offset_corrector'

module ERBLint
  module Linters
    # Run selected rubocop cops on Ruby code
    class Rubocop < Linter
      include LinterRegistry

      class ConfigSchema < LinterConfig
        property :only, accepts: array_of?(String)
        property :rubocop_config, accepts: Hash, default: {}
      end

      self.config_schema = ConfigSchema

      SUFFIX_EXPR = /[[:blank:]]*\Z/
      # copied from Rails: action_view/template/handlers/erb/erubi.rb
      BLOCK_EXPR = /\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\Z/

      def initialize(file_loader, config)
        super
        @only_cops = @config.only
        custom_config = config_from_hash(@config.rubocop_config)
        @rubocop_config = RuboCop::ConfigLoader.merge_with_default(custom_config, '')
      end

      def offenses(processed_source)
        descendant_nodes(processed_source).each_with_object([]) do |erb_node, offenses|
          offenses.push(*inspect_content(processed_source, erb_node))
        end
      end

      def autocorrect(processed_source, offense)
        return unless offense.is_a?(OffenseWithCorrection)

        lambda do |corrector|
          passthrough = Utils::OffsetCorrector.new(
            processed_source,
            corrector,
            offense.offset,
            offense.bound_range,
          )
          offense.correction.call(passthrough)
        end
      end

      private

      def descendant_nodes(processed_source)
        processed_source.ast.descendants(:erb)
      end

      class OffenseWithCorrection < Offense
        attr_reader :correction, :offset, :bound_range
        def initialize(linter, source_range, message, correction:, offset:, bound_range:)
          super(linter, source_range, message)
          @correction = correction
          @offset = offset
          @bound_range = bound_range
        end
      end

      def inspect_content(processed_source, erb_node)
        indicator, _, code_node, = *erb_node
        return if indicator&.children&.first == '#'

        original_source = code_node.loc.source
        trimmed_source = original_source.sub(BLOCK_EXPR, '').sub(SUFFIX_EXPR, '')
        alignment_column = code_node.loc.column
        aligned_source = "#{' ' * alignment_column}#{trimmed_source}"

        source = rubocop_processed_source(aligned_source, processed_source.filename)
        return unless source.valid_syntax?

        team = build_team
        team.inspect_file(source)
        team.cops.each_with_object([]) do |cop, offenses|
          correction_offset = 0
          cop.offenses.reject(&:disabled?).each do |rubocop_offense|
            if rubocop_offense.corrected?
              correction = cop.corrections[correction_offset]
              correction_offset += 1
            end

            offset = code_node.loc.start - alignment_column
            offense_range = processed_source.to_source_range(
              offset + rubocop_offense.location.begin_pos,
              offset + rubocop_offense.location.end_pos - 1,
            )

            bound_range = processed_source.to_source_range(
              code_node.loc.start,
              code_node.loc.stop
            )

            offenses << add_offense(rubocop_offense, offense_range, correction, offset, bound_range)
          end
        end
      end

      def tempfile_from(filename, content)
        Tempfile.create(File.basename(filename), Dir.pwd) do |tempfile|
          tempfile.write(content)
          tempfile.rewind

          yield(tempfile)
        end
      end

      def rubocop_processed_source(content, filename)
        RuboCop::ProcessedSource.new(
          content,
          @rubocop_config.target_ruby_version,
          filename
        )
      end

      def cop_classes
        if @only_cops.present?
          selected_cops = RuboCop::Cop::Cop.all.select { |cop| cop.match?(@only_cops) }
          RuboCop::Cop::Registry.new(selected_cops)
        elsif @rubocop_config['Rails']['Enabled']
          RuboCop::Cop::Registry.new(RuboCop::Cop::Cop.all)
        else
          RuboCop::Cop::Cop.non_rails
        end
      end

      def build_team
        RuboCop::Cop::Team.new(
          cop_classes,
          @rubocop_config,
          extra_details: true,
          display_cop_names: true,
          auto_correct: true,
          stdin: "",
        )
      end

      def config_from_hash(hash)
        inherit_from = hash&.delete('inherit_from')
        resolve_inheritance(hash, inherit_from)

        tempfile_from('.erblint-rubocop', hash.to_yaml) do |tempfile|
          RuboCop::ConfigLoader.load_file(tempfile.path)
        end
      end

      def resolve_inheritance(hash, inherit_from)
        base_configs(inherit_from)
          .reverse_each do |base_config|
          base_config.each do |k, v|
            hash[k] = hash.key?(k) ? RuboCop::ConfigLoader.merge(v, hash[k]) : v if v.is_a?(Hash)
          end
        end
      end

      def base_configs(inherit_from)
        regex = URI::DEFAULT_PARSER.make_regexp(%w(http https))
        configs = Array(inherit_from).compact.map do |base_name|
          if base_name =~ /\A#{regex}\z/
            RuboCop::ConfigLoader.load_file(RuboCop::RemoteConfig.new(base_name, Dir.pwd))
          else
            config_from_hash(@file_loader.yaml(base_name))
          end
        end

        configs.compact
      end

      def add_offense(offense, offense_range, correction, offset, bound_range)
        if offense.corrected?
          klass = OffenseWithCorrection
          options = { correction: correction, offset: offset, bound_range: bound_range }
        else
          klass = Offense
          options = {}
        end

        klass.new(self, offense_range, offense.message.strip, **options)
      end
    end
  end
end
