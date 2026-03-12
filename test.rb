#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'tmpdir'
require 'timeout'

ROOT_DIR = File.expand_path(__dir__)
EXAMPLES_DIR = File.join(ROOT_DIR, 'test', 'examples')
SLOPIT_PATH = File.join(ROOT_DIR, 'slopit.rb')

Fixture = Struct.new(:name, :dir, :manifest, keyword_init: true)

def discover_fixtures
  fixture_paths = Dir.glob(File.join(EXAMPLES_DIR, '*', 'fixture.json')).sort
  raise "No fixtures found in #{EXAMPLES_DIR}" if fixture_paths.empty?

  fixture_paths.map do |manifest_path|
    fixture_dir = File.dirname(manifest_path)

    Fixture.new(
      name: File.basename(fixture_dir),
      dir: fixture_dir,
      manifest: load_manifest(manifest_path)
    )
  end
end

def load_manifest(manifest_path)
  manifest = JSON.parse(File.read(manifest_path))
  validate_manifest!(manifest, manifest_path)
  manifest
rescue JSON::ParserError => e
  raise "Invalid fixture JSON in #{manifest_path}: #{e.message}"
end

def validate_manifest!(manifest, manifest_path)
  unless manifest.is_a?(Hash)
    raise "Fixture manifest #{manifest_path} must contain a JSON object"
  end

  expectations = manifest['expectations']
  unless expectations.is_a?(Hash)
    raise "Fixture manifest #{manifest_path} must define expectations"
  end

  required_expectation_keys = %w[max_duration_seconds verify_command verify_glob expected_stdout]
  required_expectation_keys.each do |key|
    raise "Fixture manifest #{manifest_path} is missing expectations.#{key}" unless expectations.key?(key)
  end

  unless expectations['max_duration_seconds'].is_a?(Numeric)
    raise "Fixture manifest #{manifest_path} has a non-numeric expectations.max_duration_seconds"
  end

  %w[verify_command verify_glob expected_stdout].each do |key|
    unless expectations[key].is_a?(String)
      raise "Fixture manifest #{manifest_path} has a non-string expectations.#{key}"
    end
  end

  runtime = manifest['runtime']
  advice = manifest['advice']

  validate_advice!(advice, manifest_path) unless advice.nil?

  return if runtime.nil?

  unless runtime.is_a?(Hash)
    raise "Fixture manifest #{manifest_path} has a non-object runtime"
  end

  start_command = runtime['start_command']
  unless start_command.is_a?(String) && !start_command.empty?
    raise "Fixture manifest #{manifest_path} has an invalid runtime.start_command"
  end

  ready_tcp = runtime['ready_tcp']
  return if ready_tcp.nil?

  unless ready_tcp.is_a?(Hash)
    raise "Fixture manifest #{manifest_path} has a non-object runtime.ready_tcp"
  end

  %w[host port timeout_seconds].each do |key|
    raise "Fixture manifest #{manifest_path} is missing runtime.ready_tcp.#{key}" unless ready_tcp.key?(key)
  end

  unless ready_tcp['host'].is_a?(String) && !ready_tcp['host'].empty?
    raise "Fixture manifest #{manifest_path} has an invalid runtime.ready_tcp.host"
  end

  unless ready_tcp['port'].is_a?(Integer)
    raise "Fixture manifest #{manifest_path} has a non-integer runtime.ready_tcp.port"
  end

  unless ready_tcp['timeout_seconds'].is_a?(Numeric)
    raise "Fixture manifest #{manifest_path} has a non-numeric runtime.ready_tcp.timeout_seconds"
  end
end

def validate_advice!(advice, manifest_path)
  unless advice.is_a?(Hash)
    raise "Fixture manifest #{manifest_path} has a non-object advice"
  end

  advice.each do |step_name, entries|
    unless step_name.is_a?(String) && !step_name.empty?
      raise "Fixture manifest #{manifest_path} has an invalid advice step name"
    end

    case entries
    when String
      raise "Fixture manifest #{manifest_path} has an empty advice entry for #{step_name}" if entries.strip.empty?
    when Array
      if entries.empty? || !entries.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        raise "Fixture manifest #{manifest_path} has invalid advice entries for #{step_name}"
      end
    else
      raise "Fixture manifest #{manifest_path} has invalid advice entries for #{step_name}"
    end
  end
end

def slopit(re_dir, advice)
  puts "Starting in #{re_dir}"
  env = {}
  env['SLOPIT_ADVICE_JSON'] = JSON.generate(advice) unless advice.nil? || advice.empty?
  stdout, stderr, status = Open3.capture3(env, 'ruby', SLOPIT_PATH, re_dir)
  return if status.success?

  details = [stdout, stderr].reject(&:empty?).join("\n").strip
  details = '(no output from slopit)' if details.empty?
  raise "slopit failed for #{re_dir}\n#{details}"
end

def run_fixture(fixture)
  started_at = Time.now
  runtime = nil

  puts "slopping #{fixture.name}..."
  build_dir = build_fixture(fixture)
  re_dir = stage_build_artifacts(fixture, build_dir)

  begin
    runtime = start_runtime(fixture)
    slopit(re_dir, fixture.manifest['advice'])
    enforce_duration!(Time.now - started_at, fixture.manifest.fetch('expectations').fetch('max_duration_seconds'))
    verify_output!(fixture, re_dir)
    puts "#{fixture.name} was slopt!"
  ensure
    stop_runtime(runtime)
  end
end

def configured_jobs
  jobs_value = ENV.fetch('JOBS', '2')
  jobs = Integer(jobs_value)
  raise 'JOBS must be greater than or equal to 1' if jobs < 1

  jobs
rescue ArgumentError
  raise "JOBS must be an integer, got #{jobs_value.inspect}"
end

def run_all_fixtures(fixtures)
  jobs = [configured_jobs, fixtures.length].min

  if jobs <= 1
    fixtures.each { |fixture| run_fixture(fixture) }
    return
  end

  puts "Running #{fixtures.length} fixtures with #{jobs} workers..."
  run_fixtures_in_parallel(fixtures, jobs)
end

def run_fixtures_in_parallel(fixtures, jobs)
  queue = fixtures.dup
  active_workers = {}
  failed_fixtures = []

  until queue.empty? && active_workers.empty?
    while active_workers.length < jobs && (fixture = queue.shift)
      worker = spawn_fixture_worker(fixture)
      active_workers[worker[:pid]] = worker
      puts "Started #{fixture.name} in worker #{worker[:pid]}"
    end

    pid, status = Process.wait2
    worker = active_workers.delete(pid)
    next unless worker

    print_worker_log(worker, status)
    failed_fixtures << worker[:fixture].name unless status.success?
  end

  return if failed_fixtures.empty?

  raise "Fixtures failed: #{failed_fixtures.join(', ')}"
end

def spawn_fixture_worker(fixture)
  log_path = File.join(Dir.tmpdir, "test-#{fixture.name}-#{Process.pid}-#{Time.now.to_i}.log")

  pid = fork do
    log_file = File.open(log_path, 'w')
    log_file.sync = true
    $stdout.reopen(log_file)
    $stderr.reopen(log_file)
    $stdout.sync = true
    $stderr.sync = true
    log_file.close

    begin
      run_fixture(fixture)
      exit 0
    rescue StandardError => e
      warn e.full_message(highlight: false, order: :top)
      exit 1
    end
  end

  {
    pid: pid,
    fixture: fixture,
    log_path: log_path
  }
end

def print_worker_log(worker, status)
  label = status.success? ? 'PASS' : 'FAIL'
  puts "== #{worker[:fixture].name} #{label} =="
  output = read_log(worker[:log_path])
  print output unless output.empty?
  puts if output.empty? || !output.end_with?("\n")
  FileUtils.rm_f(worker[:log_path])
end

def build_fixture(fixture)
  build_script = File.join(fixture.dir, 'build.sh')
  raise "Missing build script for #{fixture.name}: #{build_script}" unless File.file?(build_script)

  success = system('bash', './build.sh', chdir: fixture.dir)
  raise "Build failed for #{fixture.name}" unless success

  build_dir = File.join(fixture.dir, 'build')
  raise "Build directory missing for #{fixture.name}: #{build_dir}" unless Dir.exist?(build_dir)

  build_entries = Dir.children(build_dir)
  raise "Build directory is empty for #{fixture.name}: #{build_dir}" if build_entries.empty?

  build_dir
end

def stage_build_artifacts(fixture, build_dir)
  re_dir = Dir.mktmpdir("#{fixture.name}_re_dir")
  artifacts_dir = File.join(re_dir, 'artifacts')
  build_entries = Dir.children(build_dir).sort.map { |entry| File.join(build_dir, entry) }

  FileUtils.mkdir_p(artifacts_dir)
  FileUtils.cp_r(build_entries, artifacts_dir, preserve: true)

  puts "Artifacts available at #{artifacts_dir}"

  re_dir
end

def start_runtime(fixture)
  runtime_config = fixture.manifest['runtime']
  return nil if runtime_config.nil?

  log_path = File.join(Dir.tmpdir, "#{fixture.name}-runtime-#{Process.pid}.log")
  process = nil
  log_file = File.open(log_path, 'a')
  log_file.sync = true

  begin
    process = {
      pid: Process.spawn(
        'bash',
        '-lc',
        runtime_config.fetch('start_command'),
        chdir: fixture.dir,
        out: log_file,
        err: log_file,
        pgroup: true
      ),
      log_path: log_path,
      name: fixture.name
    }
  ensure
    log_file.close
  end

  wait_for_runtime_ready(process, runtime_config['ready_tcp']) if runtime_config['ready_tcp']
  process
rescue StandardError
  stop_runtime(process)
  raise
end

def wait_for_runtime_ready(process, ready_tcp)
  host = ready_tcp.fetch('host')
  port = ready_tcp.fetch('port')
  timeout_seconds = ready_tcp.fetch('timeout_seconds')

  Timeout.timeout(timeout_seconds) do
    loop do
      _, status = Process.waitpid2(process[:pid], Process::WNOHANG)
      if status
        exit_status = status.exitstatus || "signal #{status.termsig}"
        raise "#{process[:name]} runtime exited early with status #{exit_status}\n#{read_log(process[:log_path])}"
      end

      begin
        socket = TCPSocket.new(host, port)
        socket.close
        return
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
        sleep 0.1
      end
    end
  end
rescue Timeout::Error
  raise "timed out waiting for #{process[:name]} runtime on #{host}:#{port}\n#{read_log(process[:log_path])}"
end

def stop_runtime(process)
  return unless process

  pid = process[:pid]

  begin
    Process.kill('TERM', -pid)
  rescue Errno::ESRCH
    reap_process(pid)
    return
  end

  Timeout.timeout(5) do
    reap_process(pid)
  end
rescue Timeout::Error
  begin
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH
  end

  reap_process(pid)
end

def reap_process(pid)
  Process.wait(pid)
rescue Errno::ECHILD
end

def read_log(log_path)
  File.exist?(log_path) ? File.read(log_path) : ''
end

def enforce_duration!(elapsed_seconds, max_seconds)
  if elapsed_seconds > max_seconds
    raise format('reverse engineering took too long (%.2fs > %ss)', elapsed_seconds, max_seconds)
  end

  puts ' - reverse engineering done'
end

def verify_output!(fixture, re_dir)
  expectations = fixture.manifest.fetch('expectations')
  verify_pattern = File.join(re_dir, expectations.fetch('verify_glob'))
  verify_targets = Dir.glob(verify_pattern).sort
  raise "No verification targets matched #{verify_pattern}" if verify_targets.empty?

  command = "#{expectations.fetch('verify_command')} #{Shellwords.join(verify_targets)}"
  stdout, stderr, status = Open3.capture3('bash', '-lc', command)
  raise "Verification command failed for #{fixture.name}: #{stderr}" unless status.success?

  unless stdout == expectations.fetch('expected_stdout')
    puts ' - re-implementation is not correct'
    raise "Verification output mismatch for #{fixture.name}"
  end

  puts ' - re-implementation correct'
end

run_all_fixtures(discover_fixtures)
