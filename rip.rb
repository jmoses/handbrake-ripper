#!/usr/bin/env ruby

require 'rubygems'
require 'trollop'
require 'tempfile'
require 'hirb'
require 'hpricot'
require 'open-uri'
require 'fileutils'
require 'open3'

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
      
      if @best_audio_obj and @best_audio_obj.track_id != '1'
        STDERR.puts("Best audio track is not track 1!  Possible foreign language film detected!")
      end
      @best_audio_obj
    end
    
    def duration_window
      ((duration - (60 * 15))..(duration + (60 * 15)))
    end
    
    def arguments
      "--title #{title_id} #{best_audio.arguments}"
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
    
    def arguments
      "--audio #{track_id}"
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
      when /\+ (\d), ([a-zA-Z]+) \(([a-zA-Z0-9]+)\) \((.*?)\), \d+Hz, \d+bps/
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
  
  def has_real_best?
    best_title and best_title.best_audio
  end
  
  def base_command
    "HandBrakeCLI -i #{device} "
  end
  
  def best_arguments
    has_real_best? ? best_title.arguments : nil
  end
  
  def handbrake( commands )
    Open3.popen3("#{base_command} #{commands}") do |stdin, stdout, stderr|
      stderr.readlines
    end
  end
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
	opt :output_path, "Path to output files to", :default => '/mnt/MISC'
	opt :auto, "Do everything automatically", :default => false, :short => "A"
end

output_path = opts[:output_path]

unless output_path and File.exists?(output_path) and File.directory?(output_path)
  STDERR.puts("Output path (#{output_path}) is not valid.")
  exit 1 unless opts[:pretend]
end

preset = "-Z '#{opts[:preset]}'"

titles = ( opts[:title] or [1] )

filenames = []

if ! opts[:output]
  doc = Hpricot( open("http://www.imdb.com/find?s=all&q=#{ARGV.join('+')}") {|f| f.read } )
  
  possible_titles = []
  
  if table = (doc/'#main table')[1]
    (table/'tr').each do |row|
      possible_titles << (row/'td').last.inner_text.match(/(^.*?\))/)[0]
    end
  end
  if possible_titles.size == 1 and opts[:auto]
    filenames = possible_titles
  else
    filenames = Hirb::Menu.render possible_titles, :helper_class => false
  end
  
  filenames.each {|f| f.gsub!(/[:\/]/, '-') }
else
  filenames = ARGV
end

if filenames.size != titles.size
	if filenames.first !~ /%title%/
		STDERR.puts("Mismatch between number of titles and number of filenames")
		exit 1
	else
		filenames = [filenames.first]*titles.size
	end
end



cmd = %Q{HandBrakeCLI #{preset} --input #{opts[:device]} --markers --decomb --subtitle scan --subtitle-forced --native-language #{opts[:subtitle]} }
manual_cmd = %Q{ --title %d --audio #{opts[:audio]}  --output #{output_path}/"%s.mkv"}


cmds = []

if opts[:auto]
  if filenames.size != 1
    STDERR.puts("Only one filename allowed when auto ripping.")
    exit 1
  end
  
  hb = HandBrake.new( :device => opts[:device])
  hb.scan_titles
  
  if hb.has_real_best?
    cmds << cmd + hb.best_arguments + %Q{ --output #{output_path}/"#{filenames.first}.mkv"}
  else
    STDERR.puts "No best title found, please run manually."
    exit 1
  end
else
  titles.zip(filenames).each do |title, filename|
  	filename = filename.gsub('%title%', sprintf('%02d', title.to_i) )
  	cmds << sprintf(cmd + manual_cmd, title, filename)
  end
end

tf = Tempfile.new("rip")

tf << "#!/bin/bash\n"

cmds.each {|c| tf << c + "\n" }

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
