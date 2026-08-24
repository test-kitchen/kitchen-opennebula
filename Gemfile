source "https://rubygems.org"

gemspec development_group: :test

group :cookstyle do
  gem "cookstyle"
end

group :test do
  gem "rake"
  gem "rspec", "~> 3.13"
  gem "simplecov", require: false
end

# Documentation tooling. Kept out of the :test group so CI, which installs
# without the development group, never has to build it -- YARD is a local
# authoring aid and is deliberately not gated in CI.
group :development do
  gem "yard"
end
