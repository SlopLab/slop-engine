#!/usr/bin/env rake

require_relative 'test/support/harness'

desc 'Run the fixture test suite'
task :test do
  SlopEngine::TestHarness.run
rescue SlopEngine::TestHarness::SuiteFailure => e
  abort e.message
end

desc 'Remove fixture build outputs'
task :clean do
  SlopEngine::TestHarness.clean
end

task default: :test
