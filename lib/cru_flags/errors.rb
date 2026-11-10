# frozen_string_literal: true

module CruFlags
  class Error < StandardError; end

  class ParseError < Error; end

  # Normalized fetch failure. code is :http, :network, :timeout, or :parse;
  # status is set only for :http.
  class FetchError < Error
    attr_reader :code, :status

    def initialize(message, code:, status: nil)
      super(message)
      @code = code
      @status = status
    end
  end

  class ReadOnlyError < Error; end
end
