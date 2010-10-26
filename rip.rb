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
require 'json'

# Make this so it knows how to rip
class HandBrake
  class Title
    attr_accessor :title_id
    attr_accessor :audio_tracks
    attr_accessor :subtitles
    attr :duration, true
        
    BEST_AUDIO_FORMAT = 'AC3'
    BEST_AUDIO_SUBFORMAT = /5\.1/
    BEST_AUDIO_LANGUAGE = 'English'
        
    def initialize( tid )
      @title_id = tid
      @audio_tracks = []
      @duration = 0
      @subtitles = []
    end
    
    def best_audio
      @best_audio_obj ||= audio_tracks.detect {|t| t.format == BEST_AUDIO_FORMAT and t.subformat =~ BEST_AUDIO_SUBFORMAT and t.language == BEST_AUDIO_LANGUAGE}
      
      if ! @best_audio_obj and audio_tracks.size == 1
        STDERR.puts("No best audio, but only one audio track found, so we're using it.")
        @best_audio_obj = audio_tracks.first
      end
      
      if @best_audio_obj and @best_audio_obj.track_id != '1'
        STDERR.puts("Best audio track is not track 1!  Possible foreign language film detected!")
      end
      @best_audio_obj
    end
    
    def duration_window
      ((duration - (60 * 15))..(duration + (60 * 15)))
    end
    
    def rip_arguments( options = {})
      options.merge({
        :title => title_id,
        :audio => best_audio.track_id
      })
    end
  end
  
  class AudioTrack
    attr_accessor :track_id
    attr_accessor :format
    attr_accessor :subformat
    attr_accessor :language
    
    def initialize( tk_id, language, format, subformat )
      @track_id = tk_id
      @format = format
      @language = language
      @subformat = subformat
    end
    
  end
  
  class Subtitle
    attr_accessor :subtitle_id
    attr_accessor :language
    
    def initialize( sid, lang )
      @subtitle_id = sid
      @language = lang
    end
  end
  
  attr_accessor :device
  attr_accessor :titles
  attr_accessor :nodvdnav
  
  def initialize( options = {})
    options.each do |k,v|
      instance_variable_set("@#{k}", v)
    end
    @titles = []
  end
  
  def scan_titles
    current_title = nil
    handbrake("-t 0").each do |line|
      case line
      when /^\+ title (\d+)\:/
        @titles << Title.new($1)
        current_title = @titles.last
      when /\+ duration: (\d{2})\:(\d{2})\:(\d{2})/
        current_title.duration = ( $1.to_i * 3600 ) + ( $2.to_i * 60 ) + ( $3.to_i )
      when /\+ (\d), ([a-zA-Z]+) \(([a-zA-Z0-9]+)\) \((.*?)\)/ #, \d+Hz, \d+bps/
        current_title.audio_tracks << AudioTrack.new($1, $2, $3, $4)
      when /\+ (\d), ([a-zA-Z]+).*?(\(iso[\d\-]+: [a-z]+)\)/
        current_title.subtitles << Subtitle.new($1, $2)
      end
    end
  end
  
  def best_title
    return @best_title_obj if @best_title_obj
    
    @best_title_obj ||= titles.sort {|a,b| a.duration <=> b.duration }.reverse.first
    
    # if any within 15 minutes, alert
    if titles.reject {|t| t.title_id == @best_title_obj.title_id }.any? {|t| @best_title_obj.duration_window.include?(t.duration) }
      STDERR.puts "Multiple possibile titles based on duration!  Using longest title: #{@best_title_obj.title_id}"
    end

    @best_title_obj
  end
  
  def title(title_id)
    titles.detect {|t| t.title_id == title_id.to_s }
  end
  
  def has_real_best?
    best_title and best_title.best_audio
  end
  
  def base_command
    "HandBrakeCLI -i #{device} #{nodvdnav ? '--no-dvdnav ' : ''}"
  end
  
  def best_arguments(options = {})
    has_real_best? ? best_title.rip_arguments(options) : nil
  end
  
  def scan
    puts handbrake("--title 0").join("\n")
  end
  
  def handbrake( commands )
    Open3.popen3("#{base_command} #{commands}") do |stdin, stdout, stderr|
      stderr.readlines
    end
  end
  
  def rip_command( opts = {} )
    # cmd = %Q{HandBrakeCLI #{preset} --input #{opts[:device]} --markers --decomb --subtitle scan --subtitle-forced --native-language #{opts[:subtitle]} }
    #     manual_cmd = %Q{ --title %d --audio #{opts[:audio]}  --output #{output_path}/"%s.mkv"}
    #     
    opts[:title] ||= best_title.title_id if best_title
    opts[:audio] ||= best_title.best_audio.track_id if best_title and best_title.best_audio

    failed = false
    [:title, :audio, :filename, :subtitle, :preset].each do |key|
      unless opts[key] != ''
        STDERR.puts("Missing required option '#{key}' for rip.")
        failed = true
      end
    end
    raise ArgumentError.new if failed
    
    %Q{#{base_command} -Z "#{opts[:preset]}" --markers --decomb --subtitle scan --subtitle-forced --native-language #{opts[:subtitle]}  --title #{opts[:title]} --audio #{opts[:audio]},#{opts[:audio]} --output "#{opts[:filename]}" }
  end
end

def find_titles_from_imdb( title_parts )
  doc = Hpricot( open("http://www.imdb.com/find?s=tt&q=#{title_parts.join('+')}") {|f| f.read } )

  possible_titles = []
  
  if title = (doc/'.article h1.header') and title.inner_html != ''
    possible_titles << title.inner_text.strip.gsub(/\n/, ' ').squeeze(' ')
  else
    (doc/'a').each do |link|
      if link['href'] =~ /^\/title\/tt\d+/ && link.inner_text.strip != ''
        if title = link.parent.inner_text.strip and match = title.match(/(^.* \(.\d+\))/) 
          possible_titles << match[0]
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
	opt :title, "Which title to rip", :type => :integers
  opt :subtitle, "Which subtitle to use if the audio isn't in this language", :default => 'eng'
	opt :audio, "Which audio track to rip", :default => 1
	opt :preset, 'Which preset to use', :default => 'High Profile'
  # opt :search, "Search IMDB for title details", :default => false
  opt :output, "Filename to output to", :type => :string
	opt :pretend, "Just output the script to execute", :default => false
	opt :device, "Device to use", :default => '/dev/scd0'
	opt :output_path, "Path to output files to", :default => '/mnt/media/movies/'
  opt :nodvdnav, "Don't use the libdvdnav", :default => false
	opt :auto, "Do everything automatically", :default => false, :short => "A"
	opt :rename, "Search for the proper movie title and year, and rename this file", :type => :string
  opt :notify, "Notify using this prowl API token after completion", :type => :string
  opt :no_scan, "Don't scan the dvd", :default => false
  opt :start_at, "Start at this for auto titling", :default => 1, :short => "-z"
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

if opts[:start_at]
  opts[:start_at] -= 1
end

output_path = opts[:output_path]

unless output_path and File.exists?(output_path) and File.directory?(output_path)
  STDERR.puts("Output path (#{output_path}) is not valid.")
  exit 1 unless opts[:pretend]
end

titles = ( opts[:title] or [1] )

filenames = []

if ! opts[:output]
  possible_titles = find_titles_from_imdb(ARGV)
  
  if possible_titles.size == 1 and opts[:auto]
    filenames = possible_titles
  else
    filenames = Hirb::Menu.render possible_titles, :helper_class => false
  end
  
else
  filenames = opts[:output].split("|")
end


if filenames.size != titles.size #and ! opts[:output]
	if filenames.first !~ /%title%/
		STDERR.puts("Mismatch between number of titles and number of filenames")
		exit 1
	else
		filenames = [filenames.first]*titles.size
	end
end


cmds = []

hb = HandBrake.new( :device => opts[:device], :nodvdnav => opts[:nodvdnav])
hb.scan_titles unless opts[:no_scan]

if opts[:auto]
  if filenames.size != 1
    STDERR.puts("Only one filename allowed when auto ripping.")
    exit 1
  end
  
  if hb.has_real_best?
    cmds << hb.rip_command( 
      hb.best_arguments({
        :filename => File.join(output_path, "#{filenames.first}.mkv"),
        :subtitle => opts[:subtitle],
        :preset => opts[:preset]
      }) 
    )
  elsif opts[:title]
    audio = hb.title(opts[:title]).best_audio ? hb.title(opts[:title]).best_audio.track_id : opts[:audio]
    cmds << hb.rip_command({
        :filename => File.join(output_path, "#{filenames.first}.mkv"),
        :subtitle => opts[:subtitle],
        :preset => opts[:preset],
        :title => opts[:title],
        :audio => audio
    }) 
  else
    STDERR.puts "No best title found and no title specified, please run manually."
    puts hb.titles.inspect
    exit 1
  end
else
  
  titles.zip(filenames).each_with_index do |(title, filename), idx|
    cmds << hb.rip_command({
      :filename => filename.gsub('%title%', sprintf('%02d', idx + 1 + ( opts[:start_at] || 0 ) ) ) + '.mkv',
      :title => title,
      :audio => opts[:audio],
      :preset => opts[:preset],
      :subtitle => opts[:subtitle]
    })
  end
end

tf = Tempfile.new("rip")

tf << "#!/bin/bash\n"
tf << cmds.join("\n")
tf << "\n" + notify_script( filenames.first, opts[:notify] )
tf.rewind

if opts[:pretend]
  exec "cat #{tf.path} && rm #{tf.path}"
else
  puts File.read(tf.path)
  puts
  STDOUT.sync = true
  STDOUT.write "Running the above command in "
  begin
    5.downto(1) {|i| STDOUT.write("#{i}..."); sleep 1}
  rescue Interrupt
    STDOUT.puts("\nCancelling.")
    exit 0
  end
  exec "sh #{tf.path} && rm #{tf.path}"
end
