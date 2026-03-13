#!/usr/bin/env rake

require_relative 'test/support/harness'

desc 'Run the fixture test suite'
task :test do
  SlopEngine::TestHarness.run
end

desc 'Remove fixture build outputs'
task :clean do
  SlopEngine::TestHarness.clean
end

task default: :test
