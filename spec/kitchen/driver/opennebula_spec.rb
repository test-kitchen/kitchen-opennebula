require "spec_helper"

RSpec.describe Kitchen::Driver::Opennebula do
  subject(:driver) { described_class.new(config) }

  let(:config) { { template_id: 7 } }
  let!(:instance) { kitchen_instance(driver) }

  # A connection double stands in for the transport connection the driver
  # obtains from `instance.transport`.
  let(:transport_connection) do
    instance_double("Kitchen::Transport::Ssh::Connection", wait_until_ready: true, execute: true)
  end

  before do
    allow(instance.transport).to receive(:connection).and_return(transport_connection)
    allow(instance.transport).to receive(:connection).with(anything) do |_state, &block|
      block ? block.call(transport_connection) : transport_connection
    end
    # Nothing in the suite should ever actually sleep.
    allow(driver).to receive(:sleep)
  end

  describe "#status" do
    it "reports an unknown status with no vm in state" do
      expect(driver.status({})).to include(live: nil, state: "unknown")
    end

    it "reports an unknown status when OpenNebula does not know the vm" do
      allow(driver).to receive(:lookup_vm).with(42).and_return(nil)

      expect(driver.status(vm_id: 42)).to include(state: "unknown")
    end

    it "reports a running vm as live" do
      allow(driver).to receive(:lookup_vm)
        .with(42).and_return("state" => "RUNNING")

      expect(driver.status(vm_id: 42)).to include(
        live: true, state: "RUNNING", source: "driver", resource_id: "42"
      )
    end

    it "reports a booting vm as not live" do
      allow(driver).to receive(:lookup_vm).and_return("state" => "BOOT")

      expect(driver.status(vm_id: 42)).to include(live: false, state: "BOOT")
    end

    it "stamps when the check happened" do
      allow(driver).to receive(:lookup_vm).and_return("state" => "RUNNING")

      expect(driver.status(vm_id: 42)[:checked_at])
        .to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "reports an unknown status when OpenNebula cannot be reached" do
      allow(driver).to receive(:opennebula_connect)
        .and_raise(StandardError.new("boom"))

      expect(driver.status(vm_id: 42)).to include(state: "unknown")
    end
  end

  describe "#doctor" do
    before do
      allow(driver).to receive(:opennebula_credentials).and_return(%w{user pass})
    end

    it "reports no problem when template and credentials are usable" do
      expect(driver.doctor({})).to be(false)
    end

    context "with neither template_id nor template_name" do
      let(:config) { {} }

      it "reports a problem" do
        expect(driver.doctor({})).to be(true)
        expect(log_output.string).to match(/template_name or template_id not specified/)
      end
    end

    context "with both template_id and template_name" do
      let(:config) { { template_id: 7, template_name: "ubuntu" } }

      it "reports a problem" do
        expect(driver.doctor({})).to be(true)
        expect(log_output.string).to match(/Only one of template_name or template_id/)
      end
    end

    context "with unusable credentials" do
      it "reports a problem" do
        allow(driver).to receive(:opennebula_credentials)
          .and_raise(Kitchen::ActionFailed.new("Could not find one_auth file /nope"))

        expect(driver.doctor({})).to be(true)
        expect(log_output.string).to match(/Could not find one_auth file/)
      end
    end
  end

  describe "plugin metadata" do
    it "is a Test Kitchen driver" do
      expect(driver).to be_a(Kitchen::Driver::Base)
    end

    it "declares driver API version 2" do
      expect(described_class.diagnose[:api_version]).to eq(2)
    end

    it "reports its own gem version to kitchen diagnose" do
      expect(driver.diagnose_plugin[:version])
        .to eq(Kitchen::Driver::OPENNEBULA_VERSION)
    end

    it "reports a name Test Kitchen can resolve from .kitchen.yml" do
      expect(driver.name).to eq("Opennebula")
    end

    it "does not override converge, which drivers do not implement" do
      expect(described_class.instance_methods(false)).not_to include(:converge)
    end

    it "does not override verify, which drivers do not implement" do
      expect(described_class.instance_methods(false)).not_to include(:verify)
    end
  end

  describe "configuration defaults" do
    it "defaults the endpoint to a local OpenNebula daemon" do
      expect(driver[:opennebula_endpoint]).to eq("http://127.0.0.1:2633/RPC2")
    end

    it "reads the endpoint from ONE_XMLRPC when it is set" do
      with_env("ONE_XMLRPC" => "http://one.example.com:2633/RPC2") do
        expect(driver[:opennebula_endpoint]).to eq("http://one.example.com:2633/RPC2")
      end
    end

    it "reads ONE_XMLRPC lazily, so an env change after load is honoured" do
      expect(driver[:opennebula_endpoint]).to eq("http://127.0.0.1:2633/RPC2")
      with_env("ONE_XMLRPC" => "http://changed.example.com:2633/RPC2") do
        expect(described_class.new({})[:opennebula_endpoint])
          .to eq("http://changed.example.com:2633/RPC2")
      end
    end

    it "defaults the auth file to ~/.one/one_auth" do
      expect(driver[:oneauth_file]).to eq(File.join(sandbox_home, ".one", "one_auth"))
    end

    it "reads the auth file location from ONE_AUTH when it is set" do
      with_env("ONE_AUTH" => "/etc/one/auth") do
        expect(described_class.new({})[:oneauth_file]).to eq("/etc/one/auth")
      end
    end

    it "defaults sizing, login and timeout settings" do
      expect(driver.diagnose).to include(
        username: "local",
        memory: 512,
        vcpu: 1,
        cpu: 1,
        user_variables: {},
        context_variables: {},
        wait_for: 600,
        no_ssh_tcp_check: false,
        no_ssh_tcp_check_sleep: 120,
        no_passwordless_sudo_check: false,
        no_passwordless_sudo_sleep: 120,
        no_cloud_init_check: false,
        passwordless_sudo_timeout: 300,
        passwordless_sudo_retry_interval: 10,
        cloud_init_timeout: 600,
        cloud_init_retry_interval: 10
      )
    end

    it "lets provided configuration win over the defaults" do
      driver = described_class.new(memory: 4096, username: "ubuntu")
      kitchen_instance(driver)
      expect(driver[:memory]).to eq(4096)
      expect(driver[:username]).to eq("ubuntu")
    end
  end

  describe "the generated vm_hostname" do
    it "is prefixed with the instance name" do
      expect(driver[:vm_hostname]).to start_with("default-ubuntu-2404-")
    end

    it "appends a lowercase alphanumeric suffix of a fixed length" do
      suffix = driver[:vm_hostname].sub("default-ubuntu-2404-", "")
      expect(suffix).to match(/\A[a-z0-9]{8}\z/)
    end

    it "differs between instances so parallel runs do not collide" do
      suffixes = Array.new(50) { described_class.random_hostname_suffix }
      expect(suffixes.uniq.length).to be > 45
    end

    it "is not regenerated on every read" do
      expect(driver[:vm_hostname]).to eq(driver[:vm_hostname])
    end

    it "honours an explicitly configured hostname" do
      driver = described_class.new(vm_hostname: "fixed-host")
      kitchen_instance(driver)
      expect(driver[:vm_hostname]).to eq("fixed-host")
    end
  end

  describe "the discovered public_key_path" do
    it "is nil when no key exists in ~/.ssh" do
      expect(driver[:public_key_path]).to be_nil
    end

    it "finds an RSA key" do
      path = write_home_file(".ssh/id_rsa.pub", "ssh-rsa AAAA rsa\n")
      expect(driver[:public_key_path]).to eq(path)
    end

    it "finds an ed25519 key when it is the only key present" do
      path = write_home_file(".ssh/id_ed25519.pub", "ssh-ed25519 AAAA ed\n")
      expect(driver[:public_key_path]).to eq(path)
    end

    it "prefers the documented order when several keys exist" do
      write_home_file(".ssh/identity.pub", "identity")
      write_home_file(".ssh/id_ecdsa.pub", "ecdsa")
      rsa = write_home_file(".ssh/id_rsa.pub", "rsa")
      expect(driver[:public_key_path]).to eq(rsa)
    end
  end

  describe "#create" do
    let(:config) do
      {
        template_id: 7,
        public_key_path: public_key_path,
        no_ssh_tcp_check: false,
        no_passwordless_sudo_check: true,
        no_cloud_init_check: true,
      }
    end
    let(:public_key_path) { write_home_file(".ssh/id_rsa.pub", "ssh-rsa AAAAKEY comment\n") }
    let(:flavor) { fog_flavor }
    let(:vm) { fog_vm(id: 42, ip: "192.0.2.10") }
    let(:new_server) { fog_new_server(vm) }
    let(:flavors) { double("Fog::Compute::OpenNebula::Flavors", get: flavor) }
    let(:servers) { double("Fog::Compute::OpenNebula::Servers", new: new_server) }
    let(:connection) { fog_connection(servers: servers, flavors: flavors) }
    let(:state) { {} }

    before do
      allow(Fog::Compute).to receive(:new).and_return(connection)
      write_home_file(".one/one_auth", "oneadmin:opennebula\n")
    end

    it "records the VM id, address and login user in the state" do
      driver.create(state)
      expect(state).to eq(vm_id: 42, hostname: "192.0.2.10", username: "local")
    end

    it "names the VM after the configured vm_hostname" do
      expect(new_server).to receive(:name=).with(driver[:vm_hostname])
      driver.create(state)
    end

    it "waits for the VM to report itself ready before probing the transport" do
      expect(vm).to(receive(:wait_for).ordered { |&block| vm.instance_exec(&block) })
      expect(transport_connection).to receive(:wait_until_ready).ordered
      driver.create(state)
    end

    it "asks the VM itself whether it is ready" do
      expect(vm).to receive(:ready?).and_return(true)
      driver.create(state)
    end

    it "logs that the instance was created" do
      driver.create(state)
      expect(logged).to include("OpenNebula instance <default-ubuntu-2404> created.")
    end

    it "runs the inherited pre_create_command" do
      driver = described_class.new(config.merge(pre_create_command: "echo hi"))
      kitchen_instance(driver)
      allow(driver).to receive(:sleep)
      expect(driver).to receive(:run_command).with("echo hi")
      driver.create({})
    end

    it "applies the configured wait_for timeout to Fog's blocking helpers" do
      driver = described_class.new(config.merge(wait_for: 90))
      kitchen_instance(driver)
      allow(driver).to receive(:sleep)
      driver.create({})
      expect(Fog.timeout).to eq(90)
    end

    it "connects with the credentials and endpoint from the configuration" do
      expect(Fog::Compute).to receive(:new).with(
        provider: "OpenNebula",
        opennebula_username: "oneadmin",
        opennebula_password: "opennebula",
        opennebula_endpoint: "http://127.0.0.1:2633/RPC2"
      ).and_return(connection)
      driver.create(state)
    end

    context "when the API rejects the credentials" do
      let(:connection) do
        fog_connection(
          servers: servers,
          flavors: flavors,
          client: opennebula_client(version: OpenNebula::Error.new("[one.system.version] Auth failed"))
        )
      end

      it "fails with the message OpenNebula returned" do
        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, "[one.system.version] Auth failed")
      end

      it "does not create a VM" do
        expect(servers).not_to receive(:new)
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed)
      end
    end

    context "when the state already points at a live VM" do
      let(:state) { { vm_id: 42 } }
      let(:connection) do
        fog_connection(servers: servers, flavors: flavors, list_vms: [{ "id" => 42 }])
      end

      it "does not create a second VM" do
        expect(servers).not_to receive(:new)
        driver.create(state)
      end

      it "says so in the log" do
        driver.create(state)
        expect(logged).to include("OpenNebula instance <default-ubuntu-2404> already created.")
      end

      it "looks the VM up by the recorded id" do
        expect(connection).to receive(:list_vms).with({ id: 42 }).and_return([{ "id" => 42 }])
        driver.create(state)
      end
    end

    context "when the state points at a VM that no longer exists" do
      let(:state) { { vm_id: 42 } }
      let(:connection) { fog_connection(servers: servers, flavors: flavors, list_vms: []) }

      it "creates a replacement VM" do
        expect(servers).to receive(:new).and_return(new_server)
        driver.create(state)
        expect(state[:vm_id]).to eq(42)
      end
    end

    describe "template selection" do
      context "with neither template_id nor template_name" do
        let(:config) { { public_key_path: public_key_path } }

        it "tells the user what to put in .kitchen.yml" do
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /template_name or template_id not specified/
          )
        end
      end

      context "with both template_id and template_name" do
        let(:config) do
          { template_id: 7, template_name: "ubuntu", public_key_path: public_key_path }
        end

        it "refuses the ambiguous configuration" do
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Only one of template_name or template_id/
          )
        end
      end

      context "with template_id" do
        it "fetches the template by id" do
          expect(flavors).to receive(:get).with(7).and_return(flavor)
          driver.create(state)
        end

        it "fails clearly when the id matches no template" do
          allow(flavors).to receive(:get).and_return(nil)
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Could not find template to create VM/
          )
        end
      end

      context "with template_name" do
        let(:config) do
          {
            template_name: "ubuntu-24.04",
            template_uname: "oneadmin",
            template_uid: "0",
            public_key_path: public_key_path,
            no_passwordless_sudo_check: true,
            no_cloud_init_check: true,
          }
        end
        let(:flavors) { double("Fog::Compute::OpenNebula::Flavors", get_by_filter: [flavor]) }

        it "filters on name and owner" do
          expected_filter = { name: "ubuntu-24.04", uname: "oneadmin", uid: "0" }
          expect(flavors).to receive(:get_by_filter).with(expected_filter).and_return([flavor])
          driver.create(state)
        end

        it "uses the single match" do
          driver.create(state)
          expect(new_server.flavor).to be(flavor)
        end

        it "asks the user to disambiguate when the filter is too broad" do
          allow(flavors).to receive(:get_by_filter).and_return([flavor, fog_flavor(id: 2)])
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /More than one template found/
          )
        end

        it "fails clearly when nothing matches" do
          allow(flavors).to receive(:get_by_filter).and_return([])
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Could not find template to create VM/
          )
        end

        it "fails clearly when fog signals not-found with nil" do
          allow(flavors).to receive(:get_by_filter).and_return(nil)
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Could not find template to create VM/
          )
        end
      end
    end

    describe "user variables" do
      let(:config) do
        super().merge(user_variables: { ROLE: "web", "TIER" => "prod" })
      end

      it "stringifies the keys" do
        driver.create(state)
        expect(flavor.user_variables).to eq("ROLE" => "web", "TIER" => "prod")
      end

      it "keeps user variables already present on the template" do
        allow(flavor).to receive(:user_variables).and_return({ "FROM_TEMPLATE" => "1" })
        driver.create(state)
        expect(flavor.user_variables)
          .to eq("FROM_TEMPLATE" => "1", "ROLE" => "web", "TIER" => "prod")
      end

      it "initialises the section when the template leaves it unset" do
        allow(flavor).to receive(:user_variables).and_return(nil, {})
        expect(flavor).to receive(:user_variables=).with({})
        driver.create(state)
      end
    end

    describe "context variables" do
      it "injects the public key without its trailing newline" do
        driver.create(state)
        expect(flavor.context["SSH_PUBLIC_KEY"]).to eq("ssh-rsa AAAAKEY comment")
      end

      it "marks the VM as a Test Kitchen instance" do
        driver.create(state)
        expect(flavor.context["TEST_KITCHEN"]).to eq("YES")
      end

      it "merges configured context variables with stringified keys" do
        driver = described_class.new(config.merge(context_variables: { NETWORK: "YES" }))
        kitchen_instance(driver)
        allow(driver).to receive(:sleep)
        driver.create({})
        expect(flavor.context["NETWORK"]).to eq("YES")
      end

      it "lets configured context variables override the driver's own" do
        driver = described_class.new(config.merge(context_variables: { "TEST_KITCHEN" => "NO" }))
        kitchen_instance(driver)
        allow(driver).to receive(:sleep)
        driver.create({})
        expect(flavor.context["TEST_KITCHEN"]).to eq("NO")
      end

      it "initialises the section when the template leaves it unset" do
        allow(flavor).to receive(:context).and_return(nil, {})
        expect(flavor).to receive(:context=).with({})
        driver.create(state)
      end

      it "keeps context the template already carries" do
        allow(flavor).to receive(:context).and_return({ "FROM_TEMPLATE" => "1" })
        expect(flavor).not_to receive(:context=)
        driver.create(state)
        expect(flavor.context).to include("FROM_TEMPLATE" => "1", "TEST_KITCHEN" => "YES")
      end

      it "replaces the empty string fog uses for an unset section" do
        allow(flavor).to receive(:context).and_return("", {})
        expect(flavor).to receive(:context=).with({})
        driver.create(state)
      end

      context "when no public key could be discovered" do
        let(:config) { { template_id: 7, public_key_path: nil } }

        it "tells the user to configure one" do
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Set public_key_path in .kitchen.yml/
          )
        end
      end

      context "when the configured public key is missing" do
        let(:public_key_path) { File.join(sandbox_home, ".ssh", "absent.pub") }

        it "names the path it could not read" do
          expect { driver.create(state) }.to raise_error(
            Kitchen::UserError, /Could not read SSH public key .*absent\.pub/
          )
        end
      end
    end

    describe "VM sizing" do
      let(:config) { super().merge(memory: 2048, vcpu: 4, cpu: 2) }

      it "overrides the template's sizing with the configured values" do
        expect(flavor).to receive(:memory=).with(2048)
        expect(flavor).to receive(:vcpu=).with(4)
        expect(flavor).to receive(:cpu=).with(2)
        driver.create(state)
      end
    end

    describe "post-boot readiness checks" do
      let(:config) { { template_id: 7, public_key_path: public_key_path } }

      it "runs the transport, sudo and cloud-init checks in order" do
        expect(driver).to receive(:tcp_check).with(state).ordered
        expect(driver).to receive(:passwordless_sudo_check).with(state).ordered
        expect(driver).to receive(:cloud_init_check).with(state).ordered.and_return(true)
        expect(driver).to receive(:wait_for_cloud_init).with(state).ordered
        driver.create(state)
      end

      it "skips the cloud-init wait when cloud-init is not running" do
        allow(driver).to receive(:cloud_init_check).and_return(false)
        expect(driver).not_to receive(:wait_for_cloud_init)
        driver.create(state)
      end
    end
  end

  describe "#destroy" do
    let(:servers) { double("Fog::Compute::OpenNebula::Servers", destroy: true) }
    let(:connection) { fog_connection(servers: servers) }

    before do
      allow(Fog::Compute).to receive(:new).and_return(connection)
      write_home_file(".one/one_auth", "oneadmin:opennebula\n")
    end

    it "destroys the recorded VM" do
      expect(servers).to receive(:destroy).with(42)
      driver.destroy(vm_id: 42)
    end

    it "clears the VM from the state so a later create starts fresh" do
      state = { vm_id: 42, hostname: "192.0.2.10", username: "local" }
      driver.destroy(state)
      expect(state).to eq(username: "local")
    end

    it "logs the destruction" do
      driver.destroy(vm_id: 42)
      expect(logged).to include("OpenNebula instance <default-ubuntu-2404> destroyed.")
    end

    context "when the instance was never created" do
      it "is a no-op" do
        expect(servers).not_to receive(:destroy)
        driver.destroy({})
      end

      it "does not contact OpenNebula at all" do
        expect(Fog::Compute).not_to receive(:new)
        driver.destroy({})
      end

      it "does not require credentials to be present" do
        with_env("ONE_AUTH" => "/nonexistent/one_auth") do
          expect { driver.destroy({}) }.not_to raise_error
        end
      end
    end
  end

  describe "#tcp_check" do
    let(:state) { { hostname: "192.0.2.10" } }

    it "waits for the transport to accept connections" do
      expect(transport_connection).to receive(:wait_until_ready)
      driver.tcp_check(state)
    end

    it "logs readiness" do
      driver.tcp_check(state)
      expect(logged).to include("SSH ready on <default-ubuntu-2404>")
    end

    context "when the check is disabled" do
      let(:config) { { no_ssh_tcp_check: true, no_ssh_tcp_check_sleep: 30 } }

      it "sleeps for the configured period instead" do
        expect(driver).to receive(:sleep).with(30)
        driver.tcp_check(state)
      end

      it "does not probe the transport" do
        expect(transport_connection).not_to receive(:wait_until_ready)
        driver.tcp_check(state)
      end
    end
  end

  describe "#passwordless_sudo_check" do
    let(:state) { { hostname: "192.0.2.10" } }

    it "polls the guest for passwordless sudo" do
      expect(driver).to receive(:wait_for_passwordless_sudo).with(state)
      driver.passwordless_sudo_check(state)
    end

    it "logs readiness" do
      driver.passwordless_sudo_check(state)
      expect(logged).to include("Passwordless sudo ready on <default-ubuntu-2404>")
    end

    context "when the check is disabled" do
      let(:config) { { no_passwordless_sudo_check: true, no_passwordless_sudo_sleep: 45 } }

      it "sleeps for the configured period instead" do
        expect(driver).to receive(:sleep).with(45)
        expect(driver).not_to receive(:wait_for_passwordless_sudo)
        driver.passwordless_sudo_check(state)
      end
    end
  end

  describe "#wait_for_passwordless_sudo" do
    let(:state) { { hostname: "192.0.2.10" } }
    let(:sudo_denied) { ssh_failure(1, described_class::SUDO_PROBE_COMMAND) }

    it "probes with a non-interactive sudo command" do
      expect(transport_connection).to receive(:execute).with("sudo -n true > /dev/null 2>&1")
      driver.wait_for_passwordless_sudo(state)
    end

    it "returns as soon as sudo succeeds" do
      expect { driver.wait_for_passwordless_sudo(state) }.not_to raise_error
      expect(logged).not_to include("Probing for passwordless sudo")
    end

    it "retries while sudo still asks for a password" do
      call_count = 0
      allow(transport_connection).to receive(:execute) do
        call_count += 1
        raise sudo_denied if call_count < 3
      end
      driver.wait_for_passwordless_sudo(state)
      expect(call_count).to eq(3)
    end

    context "with a custom retry interval" do
      let(:config) { { passwordless_sudo_retry_interval: 7 } }

      it "waits that long between retries" do
        calls = 0
        allow(transport_connection).to receive(:execute) do
          calls += 1
          raise sudo_denied if calls == 1
        end
        expect(driver).to receive(:sleep).with(7).once
        driver.wait_for_passwordless_sudo(state)
      end
    end

    it "reports progress while it waits" do
      calls = 0
      allow(transport_connection).to receive(:execute) do
        calls += 1
        raise sudo_denied if calls == 1
      end
      driver.wait_for_passwordless_sudo(state)
      expect(logged).to match(%r{Probing for passwordless sudo ready on <default-ubuntu-2404>, elapsed \d+/300 secs})
    end

    it "gives up once the timeout has elapsed" do
      allow(transport_connection).to receive(:execute).and_raise(sudo_denied)
      allow(driver).to receive(:monotonic_time).and_return(0.0, 301.0)
      expect { driver.wait_for_passwordless_sudo(state) }.to raise_error(
        Kitchen::ActionFailed,
        "Passwordless sudo was not ready on <default-ubuntu-2404> after 300 seconds"
      )
    end

    it "does not retry a connection failure that is not a sudo password prompt" do
      failure = ssh_failure(255, described_class::SUDO_PROBE_COMMAND)
      expect(transport_connection).to receive(:execute).once.and_raise(failure)
      expect { driver.wait_for_passwordless_sudo(state) }
        .to raise_error(Kitchen::ActionFailed, failure.message)
    end
  end

  describe "#cloud_init_check" do
    let(:state) { { hostname: "192.0.2.10" } }

    it "reports that cloud-init is running when the probe succeeds" do
      expect(driver.cloud_init_check(state)).to be(true)
      expect(logged).to include("Cloud-init is running on <default-ubuntu-2404>")
    end

    it "gives cloud-init a moment to start before probing" do
      expect(driver).to receive(:sleep).with(5)
      driver.cloud_init_check(state)
    end

    it "greps the process table for cloud-init" do
      expect(transport_connection).to receive(:execute)
        .with(described_class::CLOUD_INIT_RUNNING_COMMAND)
      driver.cloud_init_check(state)
    end

    it "reports that cloud-init is absent when the probe fails" do
      allow(transport_connection).to receive(:execute)
        .and_raise(ssh_failure(1, described_class::CLOUD_INIT_RUNNING_COMMAND))
      expect(driver.cloud_init_check(state)).to be(false)
      expect(logged).to include("Cloud-init not running on <default-ubuntu-2404>")
    end

    context "when the check is disabled" do
      let(:config) { { no_cloud_init_check: true } }

      it "returns false without touching the guest" do
        expect(instance.transport).not_to receive(:connection)
        expect(driver.cloud_init_check(state)).to be(false)
      end

      it "does not sleep" do
        expect(driver).not_to receive(:sleep)
        driver.cloud_init_check(state)
      end
    end
  end

  describe "#wait_for_cloud_init" do
    let(:state) { { hostname: "192.0.2.10" } }
    let(:pending) { ssh_failure(99, described_class::CLOUD_INIT_WAIT_COMMAND) }
    let(:failed) { ssh_failure(11, described_class::CLOUD_INIT_WAIT_COMMAND) }

    it "returns once cloud-init reports success" do
      driver.wait_for_cloud_init(state)
      expect(logged).to include("Cloud-init finished successfully on <default-ubuntu-2404>")
    end

    it "polls with the cloud-init analyze command" do
      expect(transport_connection).to receive(:execute)
        .with(described_class::CLOUD_INIT_WAIT_COMMAND)
      driver.wait_for_cloud_init(state)
    end

    it "retries while cloud-init is still running" do
      calls = 0
      allow(transport_connection).to receive(:execute) do
        calls += 1
        raise pending if calls < 3
      end
      driver.wait_for_cloud_init(state)
      expect(calls).to eq(3)
      expect(logged).to match(%r{Probing for cloud-init successful completion .*, elapsed \d+/600 secs})
    end

    context "with a custom retry interval" do
      let(:config) { { cloud_init_retry_interval: 3 } }

      it "waits that long between polls" do
        calls = 0
        allow(transport_connection).to receive(:execute) do
          calls += 1
          raise pending if calls == 1
        end
        expect(driver).to receive(:sleep).with(3).once
        driver.wait_for_cloud_init(state)
      end
    end

    it "fails loudly when cloud-init reports a failed run" do
      allow(transport_connection).to receive(:execute).and_raise(failed)
      expect { driver.wait_for_cloud_init(state) }.to raise_error(
        Kitchen::ActionFailed, /Cloud-init failed on <default-ubuntu-2404>/
      )
      expect(logged).to include("Cloud-init failed on <default-ubuntu-2404>")
    end

    it "does not retry a cloud-init failure" do
      expect(transport_connection).to receive(:execute).once.and_raise(failed)
      expect { driver.wait_for_cloud_init(state) }.to raise_error(Kitchen::ActionFailed)
    end

    it "gives up once the timeout has elapsed" do
      allow(transport_connection).to receive(:execute).and_raise(pending)
      allow(driver).to receive(:monotonic_time).and_return(0.0, 601.0)
      expect { driver.wait_for_cloud_init(state) }.to raise_error(
        Kitchen::ActionFailed,
        "Cloud-init did not finish on <default-ubuntu-2404> after 600 seconds"
      )
    end

    it "surfaces an unrelated connection failure immediately" do
      failure = ssh_failure(255, described_class::CLOUD_INIT_WAIT_COMMAND)
      expect(transport_connection).to receive(:execute).once.and_raise(failure)
      expect { driver.wait_for_cloud_init(state) }
        .to raise_error(Kitchen::ActionFailed, failure.message)
    end
  end

  describe "OpenNebula credentials" do
    subject(:credentials) { driver.send(:opennebula_credentials) }

    let(:config) { {} }

    it "reads username and password from the oneauth_file" do
      path = write_home_file(".one/one_auth", "oneadmin:s3cret\n")
      driver = described_class.new(oneauth_file: path)
      kitchen_instance(driver)
      expect(driver.send(:opennebula_credentials)).to eq(%w{oneadmin s3cret})
    end

    it "strips the trailing newline the file usually carries" do
      write_home_file(".one/one_auth", "oneadmin:s3cret\n")
      expect(credentials.last).to eq("s3cret")
    end

    it "keeps colons that are part of the password" do
      write_home_file(".one/one_auth", "oneadmin:a:b:c\n")
      expect(credentials).to eq(["oneadmin", "a:b:c"])
    end

    it "prefers ONE_AUTH pointing at a file" do
      path = write_home_file("elsewhere/one_auth", "envuser:envpass")
      write_home_file(".one/one_auth", "fileuser:filepass")
      with_env("ONE_AUTH" => path) do
        expect(credentials).to eq(%w{envuser envpass})
      end
    end

    it "accepts ONE_AUTH holding the credentials inline" do
      with_env("ONE_AUTH" => "inline:secret") do
        expect(credentials).to eq(%w{inline secret})
      end
    end

    it "ignores an empty ONE_AUTH and falls back to the file" do
      write_home_file(".one/one_auth", "fileuser:filepass")
      with_env("ONE_AUTH" => "") do
        expect(credentials).to eq(%w{fileuser filepass})
      end
    end

    it "names the file it looked for when there are no credentials" do
      expect { credentials }.to raise_error(
        Kitchen::ActionFailed, %r{Could not find one_auth file .*/\.one/one_auth}
      )
    end

    it "rejects credentials with no password" do
      write_home_file(".one/one_auth", "oneadmin\n")
      expect { credentials }.to raise_error(
        Kitchen::ActionFailed, /must be in 'username:password' form/
      )
    end

    it "rejects credentials with an empty password" do
      write_home_file(".one/one_auth", "oneadmin:\n")
      expect { credentials }.to raise_error(
        Kitchen::ActionFailed, /must be in 'username:password' form/
      )
    end

    it "rejects an empty credentials file" do
      write_home_file(".one/one_auth", "\n")
      expect { credentials }.to raise_error(
        Kitchen::ActionFailed, /must be in 'username:password' form/
      )
    end
  end

  # These examples run against fog-opennebula's own in-memory mock backend
  # rather than doubles, so they fail if the real API shape the driver relies
  # on ever changes.
  describe "against the fog-opennebula mock backend" do
    let(:service) { fog_mock_service }

    before do
      allow(Fog::Compute).to receive(:new).and_return(service)
      allow(service).to receive(:client).and_return(opennebula_client)
      write_home_file(".one/one_auth", "oneadmin:opennebula\n")
      write_home_file(".ssh/id_rsa.pub", "ssh-rsa AAAAKEY comment\n")
    end

    it "recognises an existing VM by id" do
      expect(driver.send(:vm_exists?, service, 4)).to be(true)
    end

    it "recognises an unknown VM id" do
      expect(driver.send(:vm_exists?, service, 999)).to be(false)
    end

    it "treats a missing VM id as 'not created'" do
      expect(driver.send(:vm_exists?, service, nil)).to be(false)
    end

    it "resolves a template by id" do
      driver = described_class.new(template_id: 1)
      kitchen_instance(driver)
      expect(driver.send(:find_flavor, service).name).to eq("mock")
    end

    it "resolves a template by name" do
      driver = described_class.new(template_name: "mock")
      kitchen_instance(driver)
      expect(driver.send(:find_flavor, service).id).to eq(1)
    end

    it "returns a name lookup as a collection the driver can count and index" do
      matches = service.flavors.get_by_filter(name: "mock")
      expect(matches).to respond_to(:empty?, :length, :first)
      expect(matches.first).to be_a(Fog::Compute::OpenNebula::Flavor)
    end

    it "injects context into a real Flavor object" do
      driver = described_class.new(
        template_id: 1,
        public_key_path: File.join(sandbox_home, ".ssh", "id_rsa.pub"),
        context_variables: { "NETWORK" => "YES" }
      )
      kitchen_instance(driver)
      flavor = driver.send(:find_flavor, service)
      driver.send(:apply_context, flavor)
      expect(flavor.context).to eq(
        "SSH_PUBLIC_KEY" => "ssh-rsa AAAAKEY comment",
        "TEST_KITCHEN" => "YES",
        "NETWORK" => "YES"
      )
    end

    it "applies sizing to a real Flavor object" do
      driver = described_class.new(template_id: 1, memory: 2048, vcpu: 4, cpu: 2)
      kitchen_instance(driver)
      flavor = driver.send(:find_flavor, service)
      driver.send(:apply_sizing, flavor)
      expect([flavor.memory, flavor.vcpu, flavor.cpu]).to eq([2048, 4, 2])
    end
  end
end
