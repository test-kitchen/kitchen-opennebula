require "kitchen"
require "kitchen/driver/opennebula"

describe Kitchen::Driver::Opennebula do
  let(:config) { {} }
  let(:state) { {} }
  let(:instance) { double("instance") }
  let(:driver) { described_class.new(config) }

  before do
    allow(driver).to receive(:instance).and_return(instance)
    allow(driver).to receive(:info)
    allow(driver).to receive(:debug)
    allow(driver).to receive(:error)
    allow(driver).to receive(:sleep)
    allow(driver).to receive(:wait_for_passwordless_sudo)
    allow(driver).to receive(:tcp_check)
    allow(driver).to receive(:wait_for_cloud_init)
  end

  describe "#create" do
    let(:conn) { double("conn") }
    let(:servers) { double("servers") }
    let(:flavor) { double("flavor") }
    let(:vm) { double("vm", id: "123", ip: "192.168.0.1") }

    before do
      allow(driver).to receive(:opennebula_connect).and_return(conn)
      allow(conn).to receive(:servers).and_return(servers)
      allow(servers).to receive(:new).and_return(vm)
      allow(vm).to receive(:flavor=)
      allow(vm).to receive(:name=)
      allow(vm).to receive(:save)
      allow(vm).to receive(:wait_for)
      allow(driver).to receive(:cloud_init_check).and_return(true)
    end

    context "when VM is already created" do
      before do
        allow(conn).to receive(:list_vms).and_return([vm])
        allow(state).to receive(:[]).with(:vm_id).and_return("123")
      end

      it "does not create a new VM" do
        expect(driver).to_not receive(:info).with("OpenNebula instance #{instance.to_str} already created.")
        driver.create(state)
      end
    end

    context "when template_id is specified" do
      before do
        config[:template_id] = "456"
        allow(conn).to receive(:flavors).and_return(flavor)
        allow(flavor).to receive(:get).with("456").and_return(flavor)
      end

      it "sets the flavor to the specified template_id" do
        expect(vm).to receive(:flavor=).with(flavor)
        driver.create(state)
      end
    end

    context "when template_name is specified" do
      before do
        config[:template_name] = "template"
        allow(conn).to receive(:flavors).and_return(flavor)
        allow(flavor).to receive(:get_by_filter).and_return([flavor])
      end

      it "sets the flavor to the first template matching the specified template_name" do
        expect(vm).to receive(:flavor=).with(flavor)
        driver.create(state)
      end

      it "raises an error if more than one template is found" do
        allow(flavor).to receive(:length).and_return(2)
        expect { driver.create(state) }.to raise_error("More than one template found. Please restrict using template_uname")
      end
    end

    context "when template_id and template_name are both specified" do
      before do
        config[:template_id] = "456"
        config[:template_name] = "template"
      end

      it "raises an error" do
        expect { driver.create(state) }.to raise_error("Only one of template_name or template_id should be specified in .kitchen.yml")
      end
    end

    context "when template_id and template_name are not specified" do
      it "raises an error" do
        expect { driver.create(state) }.to raise_error("template_name or template_id not specified in .kitchen.yml")
      end
    end

    it "saves the new VM and updates the state" do
      expect(vm).to receive(:save)
      expect(vm).to receive(:wait_for)
      expect(state).to receive(:[]=).with(:vm_id, "123")
      expect(state).to receive(:[]=).with(:hostname, "192.168.0.1")
      expect(state).to receive(:[]=).with(:username, "local")
      driver.create(state)
    end

    it "calls tcp_check, passwordless_sudo_check, and wait_for_cloud_init" do
      expect(driver).to receive(:tcp_check).with(state)
      expect(driver).to receive(:passwordless_sudo_check).with(state)
      expect(driver).to receive(:wait_for_cloud_init).with(state)
      driver.create(state)
    end

    it "logs the creation of the instance" do
      expect(driver).to receive(:info).with("OpenNebula instance #{instance.to_str} created.")
      driver.create(state)
    end
  end

  describe "#tcp_check" do
    it "waits until the transport connection is ready" do
      expect(instance.transport).to receive(:connection).with(state).and_yield
      expect(instance.transport.connection(state)).to receive(:wait_until_ready)
      driver.tcp_check(state)
    end

    it "sleeps if no_ssh_tcp_check is true" do
      config[:no_ssh_tcp_check] = true
      config[:no_ssh_tcp_check_sleep] = 120
      expect(driver).to_not receive(:info).with("SSH ready on #{instance.to_str}")
      expect(driver).to receive(:sleep).with(120)
      driver.tcp_check(state)
    end

    it "logs that SSH is ready" do
      expect(driver).to receive(:debug).with("SSH ready on #{instance.to_str}")
      driver.tcp_check(state)
    end
  end

  describe "#passwordless_sudo_check" do
    it "calls wait_for_passwordless_sudo if no_passwordless_sudo_check is false" do
      config[:no_passwordless_sudo_check] = false
      expect(driver).to receive(:wait_for_passwordless_sudo).with(state)
      driver.passwordless_sudo_check(state)
    end

    it "sleeps if no_passwordless_sudo_check is true" do
      config[:no_passwordless_sudo_check] = true
      config[:no_passwordless_sudo_sleep] = 120
      expect(driver).to_not receive(:wait_for_passwordless_sudo)
      expect(driver).to receive(:sleep).with(120)
      driver.passwordless_sudo_check(state)
    end

    it "logs that passwordless sudo is ready" do
      expect(driver).to receive(:debug).with("Passwordless sudo ready on #{instance.to_str}")
      driver.passwordless_sudo_check(state)
    end
  end

  describe "#wait_for_passwordless_sudo" do
    let(:conn) { double("conn") }
    let(:ssh) { double("ssh") }

    before do
      allow(instance).to receive(:transport).and_return(ssh)
      allow(ssh).to receive(:connection).with(state).and_yield(conn)
      allow(conn).to receive(:execute)
    end

    it "waits until passwordless sudo is ready" do
      expect(conn).to receive(:execute).with("sudo -n true > /dev/null 2>&1")
      driver.wait_for_passwordless_sudo(state)
    end

    it "raises an error if passwordless sudo is not ready within the timeout" do
      config[:passwordless_sudo_timeout] = 300
      config[:passwordless_sudo_retry_interval] = 10
      allow(conn).to receive(:execute).and_raise(Kitchen::Transport::SshFailed, "SSH exited (1) for command: [sudo -n true > /dev/null 2>&1]")
      expect { driver.wait_for_passwordless_sudo(state) }.to raise_error(Kitchen::ActionFailed)
    end
  end

  describe "#cloud_init_check" do
    let(:conn) { double("conn") }
    let(:ssh) { double("ssh") }

    before do
      allow(instance).to receive(:transport).and_return(ssh)
      allow(ssh).to receive(:connection).with(state).and_yield(conn)
      allow(conn).to receive(:execute)
    end

    it "returns false if no_cloud_init_check is true" do
      config[:no_cloud_init_check] = true
      expect(driver.cloud_init_check(state)).to be_falsey
    end

    it "returns true if cloud-init is running" do
      expect(conn).to receive(:execute).with("ps -ef | grep cloud-init | grep -v grep >/dev/null 2>&1; exit $?")
      expect(driver).to receive(:info).with("Cloud-init is running on #{instance.to_str}")
      expect(driver.cloud_init_check(state)).to be_truthy
    end

    it "returns false if cloud-init is not running" do
      allow(conn).to receive(:execute).and_raise(Kitchen::Transport::SshFailed)
      expect(driver).to receive(:info).with("Cloud-init not running on #{instance.to_str}")
      expect(driver.cloud_init_check(state)).to be_falsey
    end
  end

  describe "#wait_for_cloud_init" do
    let(:conn) { double("conn") }
    let(:ssh) { double("ssh") }

    before do
      allow(instance).to receive(:transport).and_return(ssh)
      allow(ssh).to receive(:connection).with(state).and_yield(conn)
      allow(conn).to receive(:execute)
    end

    it "waits until cloud-init is successful" do
      config[:cloud_init_timeout] = 600
      config[:cloud_init_retry_interval] = 10
      expect(conn).to receive(:execute).with('out=$(cloud-init analyze dump| awk "/running modules for final/{nr[NR+4]; next}; NR in nr"); \
if [[ $out =~ "SUCCESS" ]]; then exit 0; elif [[ $out =~ "FAIL" ]]; then exit 11; else exit 99; fi')
      driver.wait_for_cloud_init(state)
    end

    it "raises an error if cloud-init fails" do
      allow(conn).to receive(:execute).and_raise(Kitchen::Transport::SshFailed, "SSH exited (11) for command: [out=$(cloud-init analyze dump| awk \"/running modules for final/{nr[NR+4]; next}; NR in nr\"); \
if [[ $out =~ \"SUCCESS\" ]]; then exit 0; elif [[ $out =~ \"FAIL\" ]]; then exit 11; else exit 99; fi]")
      expect { driver.wait_for_cloud_init(state) }.to raise_error(Kitchen::ActionFailed)
    end
  end

  describe "#destroy" do
    let(:conn) { double("conn") }
    let(:servers) { double("servers") }

    before do
      allow(driver).to receive(:opennebula_connect).and_return(conn)
      allow(conn).to receive(:servers).and_return(servers)
      allow(servers).to receive(:destroy)
    end

    it "destroys the VM" do
      expect(servers).to receive(:destroy).with(nil)
      driver.destroy(state)
    end
  end

  describe "#opennebula_connect" do
    let(:opennebula_creds) { "username:password" }
    let(:conn) { double("conn") }

    before do
      ENV["ONE_AUTH"] = "/path/to/one_auth"
      config[:oneauth_file] = "/path/to/one_auth"
      allow(File).to receive(:exist?).with("/path/to/one_auth").and_return(true)
      allow(File).to receive(:read).with("/path/to/one_auth").and_return(opennebula_creds)
      allow(Fog::Compute).to receive(:new).and_return(conn)
    end

    it "reads the one_auth file if ONE_AUTH environment variable is set" do
      expect(File).to receive(:read).with("/path/to/one_auth")
      driver.send(:opennebula_connect)
    end

    it "reads the one_auth file from the config if ONE_AUTH environment variable is not set" do
      ENV.delete("ONE_AUTH")
      expect(File).to receive(:read).with("/path/to/one_auth")
      driver.send(:opennebula_connect)
    end

    it "raises an error if the one_auth file cannot be found" do
      allow(File).to receive(:exist?).and_return(false)
      expect { driver.send(:opennebula_connect) }.to raise_error(Kitchen::ActionFailed, "Could not find one_auth file /path/to/one_auth")
    end

    it "returns a new Fog::Compute instance" do
      expect(Fog::Compute).to receive(:new).with({
        provider: "OpenNebula",
        opennebula_username: "username",
        opennebula_password: "password",
        opennebula_endpoint: "http://127.0.0.1:2633/RPC2",
      })
      driver.send(:opennebula_connect)
    end
  end
end
