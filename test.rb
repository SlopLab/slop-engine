#!/usr/bin/env ruby

require 'fileutils'
require 'socket'
require 'tmpdir'
require 'timeout'

def slopit(re_dir)
  root_dir = File.expand_path(File.dirname(__FILE__))

  puts "Starting in #{re_dir}"
  system("ruby #{File.join(root_dir, 'slopit.rb')} #{re_dir} 2>&1 >> /dev/null")
end

def build_hello
  root_dir = File.expand_path(File.dirname(__FILE__))
  src_dir = File.join(root_dir, 'hello-world')

  system("cd #{src_dir} && bash ./build.sh")
end

def copy_hello
  root_dir = File.expand_path(File.dirname(__FILE__))
  src_dir = File.join(root_dir, 'hello-world')
  tmp_dir = Dir.mktmpdir('hello_re_dir')

  FileUtils.mkdir_p(File.join(tmp_dir, "artifacts"))
  FileUtils.mv(File.join(src_dir, 'hello'), File.join(tmp_dir, 'artifacts', 'hello'))

  puts "Binary available at #{tmp_dir}/artifacts"

  tmp_dir
end

def build_nc
  root_dir = File.expand_path(File.dirname(__FILE__))
  src_dir = File.join(root_dir, 'network-client')

  system("cd #{src_dir} && bash ./build.sh")
end

def copy_nc
  root_dir = File.expand_path(File.dirname(__FILE__))
  src_dir = File.join(root_dir, 'network-client')
  tmp_dir = Dir.mktmpdir('nc_re_dir')

  FileUtils.mkdir_p(File.join(tmp_dir, "artifacts"))
  FileUtils.mv(File.join(src_dir, 'nc'), File.join(tmp_dir, 'artifacts', 'nc'))

  puts "Binary available at #{tmp_dir}/artifacts"

  tmp_dir
end

def start_nc_server
  root_dir = File.expand_path(File.dirname(__FILE__))
  server_path = File.join(root_dir, 'network-client', 'server.rb')
  log_path = File.join(Dir.tmpdir, "network-client-server-#{Process.pid}.log")
  supervisor_code = <<~'RUBY'
    server_path = ARGV.fetch(0)
    log_path = ARGV.fetch(1)
    stop_requested = false
    child_pid = nil

    shutdown_child = lambda do |signal|
      next unless child_pid

      begin
        Process.kill(signal, child_pid)
      rescue Errno::ESRCH
      end
    end

    Signal.trap("INT") do
      stop_requested = true
      shutdown_child.call("TERM")
    end

    Signal.trap("TERM") do
      stop_requested = true
      shutdown_child.call("TERM")
    end

    File.open(log_path, "a") do |log|
      log.sync = true

      until stop_requested
        child_pid = Process.spawn("ruby", server_path, chdir: File.dirname(server_path), out: log, err: log)
        _, status = Process.waitpid2(child_pid)
        child_pid = nil
        break if stop_requested

        log.puts("[#{Time.now.utc.iso8601}] server.rb exited with status #{status.exitstatus || "signal #{status.termsig}"}, restarting")
        sleep 0.2
      end
    end
  RUBY

  pid = Process.spawn('ruby', '-rtime', '-e', supervisor_code, server_path, log_path)

  wait_for_nc_server(pid, log_path)
  [pid, log_path]
end

def wait_for_nc_server(pid, log_path, host = 'slop-engine.de', port = 4567, timeout_sec = 10)
  Timeout.timeout(timeout_sec) do
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      if status
        raise "network-client server exited early with status #{status.exitstatus}\n#{read_log(log_path)}"
      end

      begin
        socket = TCPSocket.new(host, port)
        socket.close
        return
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
        sleep 0.1
      end
    end
  end
rescue Timeout::Error
  raise "timed out waiting for network-client server on #{host}:#{port}\n#{read_log(log_path)}"
end

def stop_process(pid)
  return unless pid

  begin
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    return
  end

  Timeout.timeout(5) do
    Process.wait(pid)
  end
rescue Timeout::Error
  begin
    Process.kill('KILL', pid)
  rescue Errno::ESRCH
    return
  end

  begin
    Process.wait(pid)
  rescue Errno::ECHILD
  end
rescue Errno::ECHILD
end

def read_log(log_path)
  File.exist?(log_path) ? File.read(log_path) : ''
end

def check_time(elapsed_sec, max_sec)
  if elapsed_sec > max_sec
    puts " - reverse engineering took too long (#{elapsed_sec}sec)"
  else
    puts " - reverse engineering done"
  end
end

def check_output(re_dir, cmd, expected)
  if `#{cmd} #{re_dir}/IMPLEMENT/*` == expected
    puts " - re-implementation correct"
  else
    puts " - re-implementation is not correct"
  end
end

t1 = Time.now
puts 'slopping hello-world...'
build_hello
re_dir = copy_hello
slopit(re_dir)
check_time(Time.now - t1, 12 * 60)
check_output(re_dir, 'cat', "puts \"Hello, World!\"\n")
puts "hello-world was slopt!"


t1 = Time.now
puts 'slopping network-client...'
build_nc
re_dir = copy_nc
server_pid, = start_nc_server
begin
  slopit(re_dir)

  check_time(Time.now - t1, 21 * 60)
  check_output(re_dir, 'ruby', "SLOPINATOR\n")
  puts "network-client was slopt!"
ensure
  stop_process(server_pid)
end
