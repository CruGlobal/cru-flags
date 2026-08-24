# frozen_string_literal: true

require "minitest/test_task"
require "standard/rake"

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/*_test.rb"]
end

task default: %i[standard test]
