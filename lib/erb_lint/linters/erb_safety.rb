# frozen_string_literal: true

require 'better_html'
require 'better_html/test_helper/safe_erb_tester'

module ERBLint
  module Linters
    # Detect unsafe ruby interpolations into javascript.
    class ErbSafety < Linter
      include LinterRegistry

      class ConfigSchema < LinterConfig
        property :better_html_config, accepts: String
      end

      self.config_schema = ConfigSchema

      def initialize(file_loader, config)
        super
        @config_filename = @config.better_html_config
      end

      def offenses(processed_source)
        offenses = []

        parser = BetterHtml::Parser.new(processed_source.file_content, template_language: :html)
        testers_for(parser).each do |tester|
          tester.validate
          tester.errors.each do |error|
            offenses << Offense.new(
              self,
              processed_source.to_source_range(error.location.start, error.location.stop),
              error.message
            )
          end
        end
        offenses
      end

      private

      def tester_classes
        [
          BetterHtml::TestHelper::SafeErb::NoStatements,
          BetterHtml::TestHelper::SafeErb::AllowedScriptType,
          BetterHtml::TestHelper::SafeErb::TagInterpolation,
          BetterHtml::TestHelper::SafeErb::ScriptInterpolation,
        ]
      end

      def testers_for(parser)
        tester_classes.map do |tester_klass|
          tester_klass.new(parser, config: better_html_config)
        end
      end

      def better_html_config
        @better_html_config ||= begin
          config_hash =
            if @config_filename.nil?
              {}
            else
              @file_loader.yaml(@config_filename).symbolize_keys
            end
          BetterHtml::Config.new(**config_hash)
        end
      end
    end
  end
end
