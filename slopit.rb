#!/usr/bin/env ruby

require 'json'

ROOT_DIR = File.dirname(__FILE__)
PROMPT_DIR  = File.join ROOT_DIR, 'prompts'

PROP_DIR = ARGV[0] || ''

unless Dir.exist? PROP_DIR
  raise "Directory #{PROP_DIR} doesn't exist!"
end

def ai(folder, prompt)
  system("cd #{folder} && claude --dangerously-skip-permissions \"#{prompt.gsub('"', '\\"')}\" --print 2>&1 >> /dev/null")
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
    ai(PROP_DIR, prompt_content['prompt'])
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
