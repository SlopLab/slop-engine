#!/usr/bin/env ruby

require 'json'
require 'open3'

ROOT_DIR = File.dirname(__FILE__)
PROMPT_DIR  = File.join ROOT_DIR, 'prompts'

PROP_DIR = ARGV[0] || ''

unless Dir.exist? PROP_DIR
  raise "Directory #{PROP_DIR} doesn't exist!"
end

class ClaudeCommandError < StandardError; end
class ClaudeUsageLimitError < ClaudeCommandError; end

CLAUDE_TIMEZONE = /[A-Za-z][A-Za-z0-9_+\-]*(?:\/[A-Za-z0-9_+\-]+)+/.freeze
CLAUDE_USAGE_LIMIT_LINE = /\AYou(?:'|\u2019)ve hit your limit · resets \d{1,2}(?::\d{2})?(?:am|pm) \((?:#{CLAUDE_TIMEZONE})\)\z/.freeze

def ai(folder, prompt, step_name)
  stdout, stderr, status = Open3.capture3(
    'claude',
    '--dangerously-skip-permissions',
    '--print',
    prompt,
    chdir: folder
  )

  return stdout if status.success?

  details = command_output(stdout, stderr)
  if claude_usage_limit_reached?(details)
    raise ClaudeUsageLimitError, "Claude usage limit reached during #{step_name}.\n#{details}"
  end

  raise ClaudeCommandError, "Claude command failed during #{step_name} (exit #{status.exitstatus || "signal #{status.termsig}"}).\n#{details}"
end

def claude_usage_limit_reached?(output)
  normalized_lines = strip_ansi(output).lines.map(&:strip).reject(&:empty?)
  normalized_lines.any? { |line| line.match?(CLAUDE_USAGE_LIMIT_LINE) }
end

def command_output(stdout, stderr)
  combined_output = [stdout, stderr].reject { |stream| stream.nil? || stream.empty? }.join("\n").strip
  return '(no output from claude)' if combined_output.empty?

  combined_output
end

def strip_ansi(output)
  output.to_s.gsub(/\e\[[0-9;]*m/, '')
end

def execute_steps
  Dir.each_child(PROMPT_DIR).sort.each do |prompt_file|
    next unless prompt_file =~ /\.prompt$/
    prompt_content = File.read(File.join(PROMPT_DIR, prompt_file))
    prompt_content = JSON.parse(prompt_content)
    t1 = Time.now
    puts "Start #{prompt_content['step']}..."
    prompt_content['expectations'].each_pair do |expectation, details|
      case expectation
      when 'create'
        details.each do |file|
	  if File.exist? File.join(PROP_DIR, file)
	    puts " - #{file} already exists"
	    raise "Expectation not satisfied"
	  end
	end
      else
        raise 'Unknown expectation'
      end
    end
    ai(PROP_DIR, prompt_content['prompt'], prompt_content['step'])
    puts "Validate #{prompt_content['step']}..."
    prompt_content['expectations'].each_pair do |expectation, details|
      case expectation
      when 'create'
        details.each do |file|
	  if File.exist? File.join(PROP_DIR, file)
	    puts " - #{file} was created"
	  else
	    puts " - #{file} was not created"
	    raise "Expectation not satisfied"
	  end
	end
      else
        raise 'Unknown expectation'
      end
    end
    t2 = Time.now
    puts "Finished #{prompt_content['step']} in #{((t2-t1) / 60.0).round}min"
  end
end

execute_steps
