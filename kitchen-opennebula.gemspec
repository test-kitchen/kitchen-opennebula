lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "kitchen/driver/opennebula_version"

Gem::Specification.new do |spec|
  spec.name = "kitchen-opennebula"
  spec.required_ruby_version = ">= 3.1"
  spec.version       = Kitchen::Driver::OPENNEBULA_VERSION
  spec.authors       = [ "BlackBerry Automation Engineering" ]
  spec.email         = [ "nonesuch@blackberry.com" ]
  spec.description   = %q{A Test Kitchen Driver for Opennebula}
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/test-kitchen/kitchen-opennebula"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = []
  spec.require_paths = ["lib"]
  spec.metadata      = {
    "bug_tracker_uri" => "https://github.com/test-kitchen/kitchen-opennebula/issues",
    "changelog_uri" => "https://github.com/test-kitchen/kitchen-opennebula/blob/main/CHANGELOG.md",
    "source_code_uri" => "https://github.com/test-kitchen/kitchen-opennebula",
  }

  spec.add_dependency "test-kitchen", ">= 3.0", "< 5.0"
  spec.add_dependency "fog-opennebula", ">= 0.0.5"
  spec.add_dependency "opennebula", ">= 4.10"

  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", "~> 3.13"

end
