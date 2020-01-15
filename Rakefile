require "bundler/gem_tasks"
require "rubocop/rake_task"
require "chefstyle"

desc "Run RuboCop on the lib directory"
RuboCop::RakeTask.new(:rubocop) do |task|
  task.patterns = ["lib/**/*.rb"]
  # don't abort rake on failure
  task.fail_on_error = false
end

desc "Display LOC stats"
task :loc do
  puts "\n## LOC Stats"
  sh "countloc -r lib/kitchen"
end

task default: %i{rubocop loc}
