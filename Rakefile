require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:test) do |t|
  t.pattern = "spec/**/*_spec.rb"
end
require "rubocop/rake_task"
require "cookstyle/chefstyle"

desc "Run RuboCop on the lib directory"
RuboCop::RakeTask.new(:rubocop) do |task|
  task.patterns = ["lib/**/*.rb"]
  # don't abort rake on failure
  task.fail_on_error = false
end

task default: %i{test rubocop}
