# -*- coding: binary -*-
require 'rex/parser/masscan_nokogiri'
require 'rex/parser/masscan_xml'
require 'open3'

module Msf

###
#
# This module provides methods for interacting with nmap.
# Modules that include this should define their own nmap_build_args()
# function, and usually should have some method for dealing with
# the data yielded from nmap_hosts(). See auxiliary/scanner/oracle/oracle_login
# for an example implementation.
#
###

module Auxiliary::Masscan

attr_accessor :massscan_args, :masscan_bin, :masscan_log
attr_reader :masscan_pid, :masscan_ver

def initialize(info = {})
  super

  register_options([
    OptAddressRange.new('RHOSTS', [ true, "The target address range or CIDR identifier"]),
    OptBool.new('NMAP_VERBOSE', [ false, 'Display nmap output', true]),
    OptString.new('RPORTS', [ false, 'Ports to target']), # RPORT supersedes RPORTS
  ], Auxiliary::Nmap)

  deregister_options("RPORT")
  @masscan_args = []
  @masscan_bin = masscan_binary_path
end

def rports
  datastore['RPORTS']
end

def rport
  datastore['RPORT']
end

def set_masscan_cmd
  self.masscan_bin || (raise RuntimeError, "Cannot locate massscan binary")
  masscan_set_log
  masscan_add_ports
  masscan_cmd = [self.nmap_bin]
  self.masscan_args.unshift("-oX #{self.masscan_log[1]}")
  masscan_cmd << self.masscan_args.join(" ")
  masscan_cmd << datastore['RHOSTS']
  masscan_cmd.join(" ")
end

def get_masscan_ver
  self.masscan_bin || (raise RuntimeError, "Cannot locate nmap binary")
  res = ""
  masscan_cmd = [self.masscan_bin]
  masscan_cmd << "--version"
  res << %x{#{masscan_cmd.join(" ")}} rescue nil
  res.gsub(/[\x0d\x0a]/n,"")
end

# Takes a version string in the form of Major.Minor and compares to
# the found version. It yells at you specifically if you try to
# compare a float b/c that's going to be a super common error.
# Comparing an Integer is okay, though.
def masscan_version_at_least?(test_ver=nil)
  raise ArgumentError, "Cannot compare a Float, use a String or Integer" if test_ver.kind_of? Float
  unless test_ver.to_s[/^([0-9]+(\x2e[0-9]+)?)/n]
    raise ArgumentError, "Bad Nmap comparison version: #{test_ver.inspect}"
  end
  test_ver_str = test_ver.to_s
  tnum_arr = $1.split(/\x2e/n)[0,2].map {|x| x.to_i}
  installed_ver = get_nmap_ver()
  vtag = installed_ver.split[2] # Should be ["Nmap", "version", "X.YZTAG", "(", "http..", ")"]
  return false if (vtag.nil? || vtag.empty?)
  return false unless (vtag =~ /^([0-9]+\x2e[0-9]+)/n) # Drop the tag.
  inum_arr = $1.split(/\x2e/n)[0,2].map {|x| x.to_i}
  return true if inum_arr[0] > tnum_arr[0]
  return false if inum_arr[0] < tnum_arr[0]
  inum_arr[1].to_i >= tnum_arr[1].to_i
end

def masscan_build_args
  raise RuntimeError, "nmap_build_args() not defined by #{self.refname}"
end

def masscan_run
  masscan_cmd = set_masscan_cmd
  begin
    masscan_pipe = ::Open3::popen3(masscan_cmd)
    @masscan_pid = masscan_pipe.last.pid
    print_status "Masscan: Starting masscan with pid #{@masscan_pid}"
    temp_masscan_threads = []
    temp_masscan_threads << framework.threads.spawn("Module(#{self.refname})-MasscanStdout", false, masscan_pipe[1]) do |np_1|
      np_1.each_line do |masscan_out|
        next if masscan_out.strip.empty?
        print_status "Masscan: #{masscan_out.strip}" if datastore['MASSCAN_VERBOSE']
      end
    end

    temp_masscan_threads << framework.threads.spawn("Module(#{self.refname})-MasscanStderr", false, masscan_pipe[2]) do |np_2|
      np_2.each_line do |masscan_err|
        next if masscan_err.strip.empty?
        print_status  "Massscan: '#{masscan_err.strip}'"
      end
    end

    temp_masscan_threads.map {|t| t.join rescue nil}
    masscan_pipe.each {|p| p.close rescue nil}
    if self.masscan_log[0].size.zero?
      print_error "Masscan Warning: Output file is empty, no useful results can be processed."
    end
  rescue ::IOError
  end
end

def masscan_binary_path
  ret = Rex::FileUtils.find_full_path("masscan") || Rex::FileUtils.find_full_path("masscan.exe")
  if ret
    fullpath = ::File.expand_path(ret)
    if fullpath =~ /\s/ # Thanks, "Program Files"
      return "\"#{fullpath}\""
    else
      return fullpath
    end
  end
end

# Returns the [filehandle, pathname], and sets the same
# to self.masscan_log.
# Only supports XML format since that's the most useful.
def masscan_set_log
  outfile = Rex::Quickfile.new("msf3-masscan-")
  if Rex::Compat.is_cygwin and self.masscan_bin =~ /cygdrive/i
    outfile_path = Rex::Compat.cygwin_to_win32(outfile.path)
  else
    outfile_path = outfile.path
  end
  self.nmap_log = [outfile,outfile_path]
end

def masscan_show_args
  print_status self.masscan_args.join(" ")
end

def masscan_append_arg(str)
  if masscan_validate_arg(str)
    self.masscan_args << str
  end
end

def masscan_reset_args
  self.masscan_args = []
end

# A helper to add in rport or rports as a -p argument
def masscan_add_ports
  if not masscan_validate_rports
    raise RuntimeError, "Cannot continue without a valid port list."
  end
  port_arg = "-p \"#{datastore['RPORT'] || rports}\""
  if masscan_validate_arg(port_arg)
    self.masscan_args << port_arg
  else
    raise RunTimeError, "Argument is invalid"
  end
end

# Validates the correctness of ports passed to masscan's -p
# option. Note that this will not validate named ports (like
# 'http'), nor will it validate when brackets are specified.
# The acceptable formats for this is:
#
# 80
# 80-90
# 22,23
# U:53,T:80
# and combinations thereof.
def massscan_validate_rports
  # If there's an RPORT specified, use that instead.
  if datastore['RPORT'] && (datastore['RPORT'].kind_of?(Fixnum) || !datastore['RPORT'].empty?)
    return true
  end
  if rports.nil? || rports.empty?
    print_error "Missing RPORTS"
    return false
  end
  rports.split(/\s*,\s*/).each do |r|
    if r =~ /^([TU]:)?[0-9]*-?[0-9]*$/
      next
    else
      print_error "Malformed masscan port: #{r}"
      return false
    end
  end
  print_status "Using RPORTS range #{datastore['RPORTS']}"
  return true
end

# Validates an argument to be passed on the command
# line to nmap. Most special characters aren't allowed,
# and commas in arguments are only allowed inside a
# quoted argument.
def masscan_validate_arg(str)
  # Check for existence
  if str.nil? || str.empty?
    print_error "Missing nmap argument"
    return false
  end
  # Check for quote balance
  if !(str.scan(/'/).size % 2).zero? or !(str.scan(/"/).size % 2).zero?
    print_error "Unbalanced quotes in nmap argument: #{str}"
    return false
  end
  # Check for characters that enable badness
  disallowed_characters = /([\x00-\x19\x21\x23-\x26\x28\x29\x3b\x3e\x60\x7b\x7c\x7d\x7e-\xff])/n
  badchar = str[disallowed_characters]
  if badchar
    print_error "Malformed nmap arguments (contains '#{badchar}'): #{str}"
    return false
  end
  # Check for commas outside of quoted arguments
  quoted_22 = /\x22[^\x22]*\x22/n
  requoted_str = str.gsub(/'/,"\"")
  if requoted_str.split(quoted_22).join[/,/]
    print_error "Malformed nmap arguments (unquoted comma): #{str}"
    return false
  end
  return true
end

# Takes a block, and yields back the host object as discovered
# by the Rex::Parser::NmapXMLStreamParser. It's up to the
# module to ferret out whatever's interesting in this host
# object.
def masscan_hosts(&block)
  @masscan_bin || (raise RuntimeError, "Cannot locate the nmap binary.")
  fh = self.nmap_log[0]
  nmap_data = fh.read(fh.stat.size)
  # fh.unlink
  if Rex::Parser.nokogiri_loaded && framework.db.active
    wspace = framework.db.find_workspace(datastore['WORKSPACE'])
    wspace ||= framework.db.workspace
    import_args = { :data => nmap_data, :wspace => wspace }
    framework.db.import_masscan_noko_stream(import_args) { |type, data| yield type, data }
  else
    nmap_parser = Rex::Parser::NmapXMLStreamParser.new
    nmap_parser.on_found_host = Proc.new { |h|
      if (h["addrs"].has_key?("ipv4"))
        addr = h["addrs"]["ipv4"]
      elsif (h["addrs"].has_key?("ipv6"))
        addr = h["addrs"]["ipv6"]
      else
        # Can't do much with it if it doesn't have an IP
        next
      end
      yield h
    }
    REXML::Document.parse_stream(masscan_data, masscan_parser)
  end
end

#Saves the data from the nmap scan to a file in the MSF::Config.local_directory
def masscan_save()
  print_status "Masscan: saving masscan log file"
  fh = self.masscan_log[0]
  masscan_data = fh.read(fh.stat.size)
  saved_path = store_local("masscan.scan.xml", "text/xml", masscan_data, "masscan_#{Time.now.utc.to_i}.xml")
  print_status "Saved Masscan XML results to #{saved_path}"
end

end
end

