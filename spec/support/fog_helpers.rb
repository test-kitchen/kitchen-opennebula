require "fog/opennebula"

# Helpers for building doubles that match the real fog-opennebula API, and for
# driving the genuine Fog mock backend in contract examples.
module FogHelpers
  # Endpoint used by the in-memory Fog mock backend.
  MOCK_ENDPOINT = "http://mock.opennebula.test:2633/RPC2".freeze

  class << self
    # Instantiates the OpenNebula service once so that Fog requires its
    # collection and request files. Until that happens the collection methods
    # (`#servers`, `#flavors`, `#list_vms`, ...) are not defined on the service
    # class and RSpec's verifying doubles would reject them.
    #
    # @return [void]
    def materialize_opennebula_service!
      Fog.mock!
      Fog::Compute.new(provider: "OpenNebula", opennebula_endpoint: MOCK_ENDPOINT)
    ensure
      Fog.unmock!
    end
  end

  # Builds a real, in-memory Fog OpenNebula service backed by fog's mock data.
  #
  # @return [Fog::Compute::OpenNebula::Mock] the mock service
  def fog_mock_service
    Fog.mock!
    Fog::Compute::OpenNebula::Mock.reset
    Fog::Compute.new(
      provider: "OpenNebula",
      opennebula_endpoint: MOCK_ENDPOINT,
      opennebula_username: "oneadmin",
      opennebula_password: "opennebula"
    )
  ensure
    Fog.unmock!
  end

  # A verifying double for an OpenNebula compute service.
  #
  # @param overrides [Hash] stubs layered on top of the defaults
  # @return [RSpec::Mocks::InstanceVerifyingDouble]
  def fog_connection(**overrides)
    instance_double(
      "Fog::Compute::OpenNebula::Real",
      { client: opennebula_client, list_vms: [] }.merge(overrides)
    )
  end

  # A double for the raw OpenNebula XML-RPC client used for the auth probe.
  #
  # @param version [Object] value returned by `#get_version`
  # @return [RSpec::Mocks::Double]
  def opennebula_client(version: "7.4.0")
    double("OpenNebula::Client", get_version: version)
  end

  # A verifying double for an OpenNebula template (a Fog flavor).
  #
  # @param overrides [Hash] stubs layered on top of the defaults
  # @return [RSpec::Mocks::InstanceVerifyingDouble]
  def fog_flavor(**overrides)
    defaults = {
      id: 1,
      name: "kitchen-template",
      user_variables: {},
      context: {},
      :user_variables= => nil,
      :context= => nil,
      :memory= => nil,
      :vcpu= => nil,
      :cpu= => nil,
    }
    instance_double("Fog::Compute::OpenNebula::Flavor", defaults.merge(overrides))
  end

  # A verifying double for a saved OpenNebula VM.
  #
  # @param overrides [Hash] stubs layered on top of the defaults
  # @return [RSpec::Mocks::InstanceVerifyingDouble]
  def fog_vm(**overrides)
    vm = instance_double(
      "Fog::Compute::OpenNebula::Server",
      { id: 42, ip: "192.0.2.10", ready?: true }.merge(overrides)
    )
    # Fog evaluates the `wait_for` block against the model itself, so the
    # driver's `vm.wait_for { ready? }` must resolve `ready?` on the VM.
    allow(vm).to receive(:wait_for) { |&block| vm.instance_exec(&block) }
    vm
  end

  # A verifying double for an unsaved VM, wired to return `vm` from `#save`.
  #
  # @param vm [Object] the object `#save` returns
  # @return [RSpec::Mocks::InstanceVerifyingDouble]
  def fog_new_server(vm)
    server = instance_double("Fog::Compute::OpenNebula::Server", :name= => nil, save: vm)
    assigned = nil
    allow(server).to receive(:flavor=) { |value| assigned = value }
    allow(server).to receive(:flavor) { assigned }
    server
  end
end
