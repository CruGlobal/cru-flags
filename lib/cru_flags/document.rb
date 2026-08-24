# frozen_string_literal: true

require "json"

module CruFlags
  module Document
    EMPTY = {"Flags" => {}.freeze}.freeze

    module_function

    # Parse and deep-freeze one flag document. Leniency is for ABSENCE, not
    # malformation: a missing Flags key is an empty document, a wrong-typed
    # one is a broken document (design doc §8).
    def parse(body)
      parsed = JSON.parse(body, freeze: true)
      raise ParseError, "document is not a JSON object" unless parsed.is_a?(Hash)

      normalize_flags(parsed)
    rescue JSON::ParserError => e
      raise ParseError, "document is not JSON: #{e.message}"
    end

    def normalize_flags(parsed)
      flags = parsed["Flags"]
      case flags
      when nil
        rebuild(parsed, {}.freeze)
      when Hash
        clean = flags.select { |_name, entry| entry.is_a?(Hash) }
        (clean.size == flags.size) ? parsed : rebuild(parsed, clean.freeze)
      else
        raise ParseError, "Flags is #{flags.class}, expected an object"
      end
    end

    def rebuild(parsed, flags)
      parsed.except("Flags").merge("Flags" => flags).freeze
    end
    private_class_method :normalize_flags, :rebuild
  end
end
