#!/usr/bin/env ruby

require 'rubygems'
require 'trollop'
require 'tempfile'
require 'hirb'
require 'hpricot'
require 'open-uri'


output_path = "/mnt/MISC/Movies/"

opts = Trollop::options do 
	opt :title, "Which title to rip", :type => :integers
	opt :subtitle, "Which subtitle to use (ie: eng)", :default => ''
	opt :audio, "Which audio track to rip", :default => 1
	opt :preset, 'Which preset to use', :default => 'film'
	opt :search, "Search IMDB for title details", :default => false
	opt :pretend, "Just output the script to execute", :default => false
end

output = ARGV


preset = case opts[:preset]
when 'animation'
 '-Z "Animation"'
when 'tv'
 '-Z "Film" -b 2000 --decomb'
else
 '-Z "Film" -b 2000'
end

titles = ( opts[:title] or [1] )

filenames = output

if opts[:search]
  doc = Hpricot( open("http://www.imdb.com/find?s=all&q=#{filenames.join('+')}") {|f| f.read } )
  
  possible_titles = []
  
  if table = (doc/'#main table')[1]
    (table/'tr').each do |row|
      possible_titles << (row/'td').last.inner_text.match(/(^.*?\))/)[0]
    end
  end
  filenames = Hirb::Menu.render possible_titles, :helper_class => false
  
  filenames.each {|f| f.gsub!(/[:\/]/, '-') }
end

if filenames.size != titles.size
	if filenames.first !~ /%title%/
		STDERR.puts("Mismatch between number of titles and number of filenames")
		exit 1
	else
		filenames = [filenames.first]*titles.size
	end
end

cmd = %Q{HandBrakeCLI #{preset}  -t %d -a #{opts[:audio]} #{opts[:subtitle] != '' ? "-N #{opts[:subtitle]}" : ''} -i /dev/scd0 -m -o /mnt/MISC/"%s.mkv"}

cmds = []

titles.zip(filenames).each do |title, filename|
	filename = filename.gsub('%title%', sprintf('%02d', title.to_i) )
	cmds << sprintf(cmd, title, filename)
end


tf = Tempfile.new("rip")

tf << "#!/bin/bash\n"

cmds.each {|c| tf << c + "\n" }

tf.rewind

if opts[:pretend]
  exec "cat #{tf.path} && rm #{tf.path}"
else
  exec "sh #{tf.path} && rm #{tf.path}"
end
