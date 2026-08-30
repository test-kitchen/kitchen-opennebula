#
# Copyright (C) 2019, BlackBerry, Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "tmpdir"
require "stringio"

# fog-opennebula still registers its service under the legacy
# Fog::Compute::OpenNebula constant, which makes fog-core log a deprecation
# notice every time the service is built. It is not actionable from here and
# it drowns out the test output.
require "fog/core"
Fog::Logger[:deprecation] = nil

require "kitchen"
require "kitchen/provisioner/dummy"
require "kitchen/transport/dummy"
require "kitchen/verifier/dummy"
require "kitchen/driver/opennebula"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

# Fog resolves a service's collections and requests lazily, the first time the
# service is instantiated. Materialize the OpenNebula service once up front so
# that `instance_double` can verify against the real method surface.
FogHelpers.materialize_opennebula_service!

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = ".rspec_status"
  Kernel.srand config.seed

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
    mocks.syntax = :expect
  end

  config.include EnvHelpers
  config.include FogHelpers
  config.include KitchenHelpers

  # Every example gets a private HOME so that the developer's real ~/.ssh and
  # ~/.one never leak into a test, and so that OpenNebula environment variables
  # start from a known-empty state.
  config.around do |example|
    Dir.mktmpdir("kitchen-opennebula-home") do |home|
      with_env("HOME" => home, "ONE_AUTH" => nil, "ONE_XMLRPC" => nil) do
        @sandbox_home = home
        example.run
      end
    end
  end
end
