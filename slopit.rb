#!/usr/bin/env ruby

require 'json'
require 'open3'

ROOT_DIR = File.dirname(__FILE__)
PROMPT_DIR  = File.join ROOT_DIR, 'prompts'
SUPPORTED_AI_PROVIDERS = %w[claude codex].freeze
CLAUDE_FALLBACK_BIN = File.join(Dir.home, '.local', 'bin', 'claude')
CODEX_FALLBACK_BIN = File.join(Dir.home, '.npm-global', 'bin', 'codex')

PROP_DIR = ARGV[0] || ''

unless Dir.exist? PROP_DIR
  raise "Directory #{PROP_DIR} doesn't exist!"
end

class AIProviderConfigurationError < StandardError; end
class AICommandError < StandardError; end
class ClaudeCommandError < AICommandError; end
class CodexCommandError < AICommandError; end
class ClaudeUsageLimitError < ClaudeCommandError; end

CLAUDE_TIMEZONE = /[A-Za-z][A-Za-z0-9_+\-]*(?:\/[A-Za-z0-9_+\-]+)+/.freeze
CLAUDE_USAGE_LIMIT_LINE = /\AYou(?:'|\u2019)ve hit your limit · resets \d{1,2}(?::\d{2})?(?:am|pm) \((?:#{CLAUDE_TIMEZONE})\)\z/.freeze

def ai(folder, prompt, step_name)
  provider = ai_provider
  stdout, stderr, status = run_ai_command(provider, folder, prompt)

  return stdout if status.success?

  details = command_output(provider, stdout, stderr)
  if provider == 'claude' && claude_usage_limit_reached?(details)
    raise ClaudeUsageLimitError, "Claude usage limit reached during #{step_name}.\n#{details}"
  end

  raise provider_error_class(provider), "#{provider.capitalize} command failed during #{step_name} (exit #{status.exitstatus || "signal #{status.termsig}"}).\n#{details}"
end

def ai_provider
  provider = ENV.fetch('SLOPIT_AI_PROVIDER', 'claude').downcase
  return provider if SUPPORTED_AI_PROVIDERS.include?(provider)

  raise AIProviderConfigurationError, "Unsupported AI provider #{provider.inspect}. Supported providers: #{SUPPORTED_AI_PROVIDERS.join(', ')}"
end

def run_ai_command(provider, folder, prompt)
  case provider
  when 'claude'
    Open3.capture3(
      resolve_executable('claude', env_var: 'SLOPIT_CLAUDE_BIN', fallback: CLAUDE_FALLBACK_BIN),
      '--dangerously-skip-permissions',
      '--print',
      prompt,
      chdir: folder
    )
  when 'codex'
    Open3.capture3(
      resolve_executable('codex', env_var: 'SLOPIT_CODEX_BIN', fallback: CODEX_FALLBACK_BIN),
      'exec',
      '--skip-git-repo-check',
      '--dangerously-bypass-approvals-and-sandbox',
      '--color',
      'never',
      prompt,
      chdir: folder
    )
  else
    raise AIProviderConfigurationError, "Unsupported AI provider #{provider.inspect}"
  end
end

def resolve_executable(default_name, env_var:, fallback:)
  candidates = [ENV[env_var], default_name, fallback].compact

  candidates.each do |candidate|
    resolved = executable_path(candidate)
    return resolved if resolved
  end

  raise AIProviderConfigurationError, "Unable to find executable for #{default_name}. Checked #{env_var}, PATH, and #{fallback}."
end

def executable_path(candidate)
  return candidate if candidate.include?(File::SEPARATOR) && File.executable?(candidate)

  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |path_entry|
    path = File.join(path_entry, candidate)
    return path if File.executable?(path)
  end

  nil
end

def provider_error_class(provider)
  case provider
  when 'claude'
    ClaudeCommandError
  when 'codex'
    CodexCommandError
  else
    AICommandError
  end
end

def claude_usage_limit_reached?(output)
  normalized_lines = strip_ansi(output).lines.map(&:strip).reject(&:empty?)
  normalized_lines.any? { |line| line.match?(CLAUDE_USAGE_LIMIT_LINE) }
end

def command_output(provider, stdout, stderr)
  combined_output = [stdout, stderr].reject { |stream| stream.nil? || stream.empty? }.join("\n").strip
  return "(no output from #{provider})" if combined_output.empty?

  combined_output
end

def strip_ansi(output)
  output.to_s.gsub(/\e\[[0-9;]*m/, '')
end

def tooling_advice
  raw_advice = ENV['SLOPIT_ADVICE_JSON']
  return {} if raw_advice.nil? || raw_advice.empty?

  parsed_advice = JSON.parse(raw_advice)
  validate_tooling_advice!(parsed_advice)
  parsed_advice
rescue JSON::ParserError => e
  raise "Invalid SLOPIT_ADVICE_JSON: #{e.message}"
end

def validate_tooling_advice!(advice)
  unless advice.is_a?(Hash)
    raise 'SLOPIT_ADVICE_JSON must contain a JSON object'
  end

  advice.each do |step_name, entries|
    unless step_name.is_a?(String) && !step_name.empty?
      raise 'SLOPIT_ADVICE_JSON contains an invalid advice step name'
    end

    case entries
    when String
      raise "SLOPIT_ADVICE_JSON contains an empty advice entry for #{step_name}" if entries.strip.empty?
    when Array
      if entries.empty? || !entries.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        raise "SLOPIT_ADVICE_JSON contains invalid advice entries for #{step_name}"
      end
    else
      raise "SLOPIT_ADVICE_JSON contains invalid advice entries for #{step_name}"
    end
  end
end

def advice_entries(advice, key)
  entries = advice[key]

  case entries
  when nil
    []
  when String
    [entries]
  else
    entries
  end
end

def prompt_with_advice(prompt, step_name, advice)
  entries = advice_entries(advice, 'all') + advice_entries(advice, step_name)
  return prompt if entries.empty?

  [
    prompt,
    '',
    'Additional advice for this fixture:',
    entries.map { |entry| "- #{entry}" }
  ].flatten.join("\n")
end

def execute_steps
  advice = tooling_advice

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
    ai(PROP_DIR, prompt_with_advice(prompt_content['prompt'], prompt_content['step'], advice), prompt_content['step'])
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
