#!/usr/bin/env ruby

require 'rubygems'
require 'trollop'
require 'tempfile'
require 'hirb'
require 'hpricot'
require 'open-uri'
require 'fileutils'
require 'open3'
require 'cgi'
require 'uri'
require 'json'

def find_titles_from_imdb( title_parts )
  names = title_parts.map do |part|
    URI.encode(File.basename(part))
  end

  doc = Hpricot( open("http://www.imdb.com/find?s=tt&q=#{names.join('+')}") {|f| f.read } )

  possible_titles = []
  
  if title = (doc/'.article h1.header') and title.inner_html != ''
    possible_titles << title.inner_text.strip.gsub(/\n/, ' ').squeeze(' ')
  else
    (doc/'a').each do |link|
      if link['href'] =~ /^\/title\/tt\d+/ && link.inner_text.strip != ''
        if title = link.parent.inner_text.strip and match = title.match(/(^.* \(.\d+\))/) 
          possible_titles << match[0] unless match[0] =~ /^Media from/
        end
      end
    end
  end

  possible_titles.reject{|x| x.nil? || x == '' }[0..10].collect {|t| t.gsub(/&#x\d+;/, '').gsub(/[:\/]/, '-') }
end

def notify_script( title, api_key = nil )
  return "" unless api_key
  
  return %Q{ruby -rrubygems -e 'require "prowl"; Prowl.add(:application => "HBRip", :event => "Completed", :description => "#{title} is done.", :apikey => "#{api_key}")'}
end


opts = Trollop::options do 
  opt :output, "Filename to output to", :type => :string
  opt :output_path, "Path to encode file to", :type => :string
	opt :rename, "Search for the proper movie title and year, and rename this file", :type => :string
end

# Growl support instead?
if opts[:notify] or opts[:notify_internal]
  begin
    require 'prowl'
  rescue LoadError
    STDERR.puts("Error loading prowl, skipping notifications!")
    opts[:notify] = nil
  end
end

if opts[:rename]
  unless File.exists?( opts[:rename] )
    STDERR.puts("Can't find file to rename!")
    exit 1
  end
  
  if File.basename(opts[:rename]) =~ /^([ A-Za-z0-9']+)/
    title = Hirb::Menu.render find_titles_from_imdb([$1]), :helper_class => false
    
    if title
      FileUtils.mv( opts[:rename], File.join( File.dirname(opts[:rename]), "#{title}#{File.extname(opts[:rename])}"))
    end
  end
  exit 0
end


if ! opts[:output]
  possible_titles = find_titles_from_imdb(ARGV)
  
  if possible_titles.size == 1 and opts[:auto]
    filenames = possible_titles
  else
    filenames = Hirb::Menu.render possible_titles, :helper_class => false
  end
end

cmd = <<-CMD
HandBrakeCLI -Z 'High Profile' "#{ARGV[0]}" "#{File.join(opts[:output_path], [filenames || opts[:output]].flatten.first)}.mp4"
CMD

puts cmd

