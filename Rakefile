# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "standard/rake"

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/*_test.rb"]
end

# release-please owns tagging and the GitHub release; rubygems/release-gem
# hard-codes `bundle exec rake release`, and bundler's stock release task
# would mint a duplicate v-prefixed tag alongside release-please's
# cru-flags/vX.Y.Z. So "release" drops only bundler's source_control_push
# step (the tagging one) and keeps the rest of its stock order —
# release:guard_clean in particular, without which a local `rake release`
# would happily publish a gem built from an uncommitted working tree.
Rake::Task["release"].clear
desc "Build the gem and push it to rubygems.org (tagging belongs to release-please)"
task release: %w[build release:guard_clean release:rubygem_push]

task default: %i[standard test]
