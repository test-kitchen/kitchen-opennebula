require "bundler/gem_tasks"
require "rspec/core/rake_task"

desc "Run the unit tests"
RSpec::Core::RakeTask.new(:test) do |t|
  t.pattern = "spec/**/*_spec.rb"
end

desc "Run Cookstyle/Chefstyle over the project, exactly as CI does"
task :rubocop do
  # don't abort rake on failure
  sh("cookstyle --chefstyle") { |ok, _res| warn("Cookstyle reported offenses") unless ok }
end

# YARD is an authoring aid only. It lives in the :development bundle group,
# which CI installs without, and is deliberately kept out of the default task
# so documentation is never a merge gate.
begin
  require "yard"

  YARD::Rake::YardocTask.new(:doc) do |t|
    t.files = ["lib/**/*.rb"]
    t.options = ["--no-private", "--markup", "markdown"]
  end

  desc "List anything in lib/ that is still undocumented"
  task :doc_coverage do
    sh "yard stats --list-undoc lib/**/*.rb"
  end
rescue LoadError
  desc "Generate YARD documentation (not installed)"
  task :doc do
    abort "YARD is not installed. Run: bundle config unset without && bundle install"
  end
end

task default: %i{test rubocop}
