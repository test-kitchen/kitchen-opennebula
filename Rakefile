require 'bundler'
require 'bundler/gem_tasks'
require 'cane/rake_task'

desc "Run cane to check quality metrics"
Cane::RakeTask.new do |cane|
  cane.abc_max = 80
  cane.style_measure = 120
end

desc "Display LOC stats"
task :stats do
  puts "\n## Production Code Stats"
  sh "countloc -r lib"
end

desc "Run all quality tasks"
task :quality => [:cane]

task :default => [:quality]
