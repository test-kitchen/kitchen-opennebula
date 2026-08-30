# A minimal, in-memory stand-in for an OpenNebula XML-RPC daemon.
#
# It implements just enough of the OpenNebula API for this driver to build,
# poll and delete a VM -- the handful of `one.*` methods the `opennebula` gem
# calls on the driver's behalf. It exists so that the Test Kitchen integration
# suites can drive the real driver, through the real fog-opennebula and
# opennebula gems, without an OpenNebula cloud.
#
# It is deliberately strict about what the driver sends: a VM whose CONTEXT is
# missing the SSH public key or the TEST_KITCHEN marker is rejected, so a
# regression in the driver's contextualization fails the integration run rather
# than passing quietly.
#
# Run the whole integration cycle with `bundle exec rake integration`, or start
# just the daemon with `ruby test/support/fake_opennebula.rb`.

require "webrick"
require "xmlrpc/server"

# An OpenNebula XML-RPC daemon that keeps its whole world in memory.
class FakeOpennebula
  # Credentials the daemon accepts, in OpenNebula's `username:password` form.
  CREDENTIALS = "oneadmin:opennebula".freeze

  # The OpenNebula version the daemon claims to be.
  VERSION = "7.4.0".freeze

  # OpenNebula's authentication failure code.
  AUTHENTICATION_ERROR = 0x0100

  # OpenNebula's "no such object" code.
  NO_EXISTS_ERROR = 0x0400

  # OpenNebula's generic action failure code.
  ACTION_ERROR = 0x0800

  # STATE 3 (ACTIVE) with LCM_STATE 3 (RUNNING) is what fog-opennebula reads as
  # a VM that is up and ready.
  ACTIVE_STATE = 3

  # See {ACTIVE_STATE}.
  RUNNING_LCM_STATE = 3

  # The address every VM is given. It is the loopback address so that a
  # transport which really does connect has somewhere harmless to go.
  VM_ADDRESS = "127.0.0.1".freeze

  # Templates the daemon serves, keyed by id. Two templates deliberately share
  # a name so that the "more than one template found" path can be exercised.
  TEMPLATES = {
    1 => { name: "kitchen", uname: "oneadmin", uid: "0" },
    2 => { name: "duplicate", uname: "oneadmin", uid: "0" },
    3 => { name: "duplicate", uname: "someone-else", uid: "1" },
  }.freeze

  # @param port [Integer] TCP port to listen on
  # @param host [String] address to bind to
  def initialize(port:, host: "127.0.0.1")
    @port = port
    @host = host
    @vms = {}
    @next_id = 0
    @mutex = Mutex.new
  end

  # Starts serving and blocks until the process is interrupted.
  #
  # @return [void]
  def start
    server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: @host,
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
      AccessLog: []
    )
    server.mount("/RPC2", servlet)
    %w{INT TERM}.each { |signal| trap(signal) { server.shutdown } }
    warn("fake OpenNebula listening on http://#{@host}:#{@port}/RPC2")
    server.start
  end

  private

  # @return [XMLRPC::WEBrickServlet] the servlet with every supported method
  def servlet
    XMLRPC::WEBrickServlet.new.tap do |servlet|
      servlet.add_handler("one.system.version") { |auth| respond(auth) { VERSION } }
      servlet.add_handler("one.vm.allocate") { |auth, description, *| respond(auth) { allocate(description) } }
      servlet.add_handler("one.vm.info") { |auth, id, *| respond(auth) { vm_xml(id) } }
      servlet.add_handler("one.vm.recover") { |auth, id, *| respond(auth) { recover(id) } }
      servlet.add_handler("one.templatepool.info") do |auth, _who, start_id, end_id, *|
        respond(auth) { template_pool_xml(start_id, end_id) }
      end
      %w{one.vmpool.info one.vmpool.infoextended}.each do |method|
        servlet.add_handler(method) do |auth, _who, start_id, end_id, *|
          respond(auth) { vm_pool_xml(start_id, end_id) }
        end
      end
      servlet.set_default_handler do |name, *|
        [false, "Unimplemented method #{name}", ACTION_ERROR]
      end
    end
  end

  # Wraps a handler in OpenNebula's [success, payload, error code] response
  # shape and its credential check.
  #
  # @param auth [String] the credentials the caller sent
  # @return [Array(Boolean, Object, Integer)] an OpenNebula XML-RPC response
  def respond(auth)
    unless auth == CREDENTIALS
      return [false, "User couldn't be authenticated, aborting call.", AUTHENTICATION_ERROR]
    end

    [true, yield, 0]
  rescue ArgumentError => e
    [false, e.message, ACTION_ERROR]
  rescue KeyError => e
    [false, e.message, NO_EXISTS_ERROR]
  end

  # @param description [String] the VM template the driver rendered
  # @return [Integer] the new VM's id
  # @raise [ArgumentError] if the driver left out anything a VM needs
  def allocate(description)
    name = description[/^NAME\s*=\s*"([^"]*)"/, 1]
    raise ArgumentError, "VM template has no NAME: #{description}" if name.nil? || name.empty?

    context = description[/CONTEXT\s*=\s*\[(.*?)\]/m, 1].to_s
    unless context.include?('"TEST_KITCHEN"="YES"')
      raise ArgumentError, "VM context is missing the TEST_KITCHEN marker: #{context.inspect}"
    end
    unless context.match?(/"SSH_PUBLIC_KEY"="\S+/)
      raise ArgumentError, "VM context is missing SSH_PUBLIC_KEY: #{context.inspect}"
    end

    @mutex.synchronize do
      id = @next_id
      @next_id += 1
      @vms[id] = { id: id, name: name }
      id
    end
  end

  # @param id [Integer] the VM to delete
  # @return [Integer] the deleted VM's id
  # @raise [KeyError] if no such VM exists
  def recover(id)
    @mutex.synchronize do
      raise KeyError, "Error getting virtual machine [#{id}]." unless @vms.delete(id)
    end
    id
  end

  # @param id [Integer] the VM to describe
  # @return [String] a VM document
  # @raise [KeyError] if no such VM exists
  def vm_xml(id)
    vm = @mutex.synchronize do
      @vms.fetch(id) { raise KeyError, "Error getting virtual machine [#{id}]." }
    end
    render_vm(vm)
  end

  # @param start_id [Integer] first id to include, or -1 for no lower bound
  # @param end_id [Integer] last id to include, or -1 for no upper bound
  # @return [String] a VM pool document
  def vm_pool_xml(start_id, end_id)
    vms = @mutex.synchronize { @vms.values.select { |vm| in_range?(vm[:id], start_id, end_id) } }
    "<VM_POOL>#{vms.map { |vm| render_vm(vm) }.join}</VM_POOL>"
  end

  # @param start_id [Integer] first id to include, or -1 for no lower bound
  # @param end_id [Integer] last id to include, or -1 for no upper bound
  # @return [String] a template pool document
  def template_pool_xml(start_id, end_id)
    body = TEMPLATES.select { |id, _| in_range?(id, start_id, end_id) }.map do |id, template|
      render_template(id, template)
    end
    "<VMTEMPLATE_POOL>#{body.join}</VMTEMPLATE_POOL>"
  end

  # @return [Boolean] whether id falls inside an OpenNebula id range, in which
  #   a negative bound means "unbounded"
  def in_range?(id, start_id, end_id)
    (start_id.to_i < 0 || id >= start_id.to_i) &&
      (end_id.to_i < 0 || id <= end_id.to_i)
  end

  def render_vm(vm)
    <<~XML
      <VM>
        <ID>#{vm[:id]}</ID>
        <UID>0</UID>
        <GID>0</GID>
        <UNAME>oneadmin</UNAME>
        <GNAME>oneadmin</GNAME>
        <NAME>#{vm[:name]}</NAME>
        <STATE>#{ACTIVE_STATE}</STATE>
        <LCM_STATE>#{RUNNING_LCM_STATE}</LCM_STATE>
        <TEMPLATE>
          <CPU>1</CPU>
          <VCPU>1</VCPU>
          <MEMORY>512</MEMORY>
          <NIC>
            <IP>#{VM_ADDRESS}</IP>
            <MAC>02:00:7f:00:00:01</MAC>
            <NETWORK>kitchen</NETWORK>
          </NIC>
        </TEMPLATE>
      </VM>
    XML
  end

  def render_template(id, template)
    <<~XML
      <VMTEMPLATE>
        <ID>#{id}</ID>
        <UID>#{template[:uid]}</UID>
        <GID>0</GID>
        <UNAME>#{template[:uname]}</UNAME>
        <GNAME>oneadmin</GNAME>
        <NAME>#{template[:name]}</NAME>
        <TEMPLATE>
          <CPU>1</CPU>
          <VCPU>1</VCPU>
          <MEMORY>512</MEMORY>
          <CONTEXT>
            <NETWORK>YES</NETWORK>
          </CONTEXT>
        </TEMPLATE>
      </VMTEMPLATE>
    XML
  end
end

FakeOpennebula.new(port: Integer(ENV.fetch("ONE_PORT", "12633"))).start if $PROGRAM_NAME == __FILE__
