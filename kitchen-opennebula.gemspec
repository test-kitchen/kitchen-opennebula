# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "kitchen/driver/opennebula_version"

Gem::Specification.new do |spec|
  spec.name          = "kitchen-opennebula"
  spec.version       = Kitchen::Driver::OPENNEBULA_VERSION
  spec.authors       = [ "BlackBerry Automation Engineering" ]
  spec.email         = [ "nonesuch@blackberry.com" ]
  spec.description   = %q{A Test Kitchen Driver for Opennebula}
  spec.summary       = spec.description
  spec.homepage      = ""
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = []
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "test-kitchen", ">= 1.2", "< 4.0"
  spec.add_dependency "fog", ">= 1.30", "< 3.0"
  spec.add_dependency "opennebula", ">= 4.10"
end
