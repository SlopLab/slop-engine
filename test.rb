#!/usr/bin/env ruby

require 'fileutils'
require 'tmpdir'

def slopit(re_dir)
  root_dir = File.expand_path(File.dirname(__FILE__))

  puts "Starting in #{re_dir}"
  system("ruby #{File.join(root_dir, 'slopit.rb')} #{re_dir}")
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

t1 = Time.now
puts 'slopping hello-world...'
build_hello
re_dir = copy_hello
slopit(re_dir)
t2 = Time.now
hello_exe_time_sec = t2 - t1
if hello_exe_time_sec > (12 * 60)
  puts " - reverse engineering took to long (#{hello_exe_time_sec}sec)"
else
  puts " - reverse engineering done"
end
unless `cat #{re_dir}/IMPLEMENT/*` == "puts \"Hello, World!\"\n"
  puts " - re-implementation is not correct"
else
  puts " - re-implementation correct"
end
puts "hello-world was slopt!"

