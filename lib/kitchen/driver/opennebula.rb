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

require "fog/opennebula"
require "kitchen"
require "kitchen/transport/ssh"

module Kitchen

  module Driver

    # Test Kitchen driver that provisions instances on an OpenNebula cloud.
    #
    # The driver talks to OpenNebula's XML-RPC API through `fog-opennebula`. A
    # VM is instantiated from an existing OpenNebula template (selected either
    # by `template_id` or by `template_name`), the SSH public key and Test
    # Kitchen context variables are injected into the template's `CONTEXT`
    # section, and the driver then blocks until the VM is reachable and ready
    # to converge.
    #
    # @example minimal .kitchen.yml
    #   driver:
    #     name: opennebula
    #     template_name: ubuntu-24.04
    #
    # @see https://kitchen.ci/docs/drivers/ Test Kitchen driver documentation
    class Opennebula < Kitchen::Driver::Base
      kitchen_driver_api_version 2

      # Characters used to build the random suffix of a generated VM hostname.
      HOSTNAME_CHARS = [*"a".."z", *"0".."9"].freeze

      # Number of random characters appended to a generated VM hostname.
      HOSTNAME_SUFFIX_LENGTH = 8

      # Command used to probe for passwordless sudo on the guest.
      SUDO_PROBE_COMMAND = "sudo -n true > /dev/null 2>&1".freeze

      # Command used to detect whether cloud-init is running on the guest.
      CLOUD_INIT_RUNNING_COMMAND =
        "ps -ef | grep cloud-init | grep -v grep >/dev/null 2>&1; exit $?".freeze

      # Exit code returned by {CLOUD_INIT_WAIT_COMMAND} when cloud-init failed.
      CLOUD_INIT_FAILED_EXIT = 11

      # Exit code returned by {CLOUD_INIT_WAIT_COMMAND} when cloud-init is
      # still running.
      CLOUD_INIT_PENDING_EXIT = 99

      # Command used to poll cloud-init for successful completion. It exits 0
      # on success, {CLOUD_INIT_FAILED_EXIT} on failure and
      # {CLOUD_INIT_PENDING_EXIT} while cloud-init is still working.
      CLOUD_INIT_WAIT_COMMAND =
        'out=$(cloud-init analyze dump| awk "/running modules for final/{nr[NR+4]; next}; NR in nr"); ' \
        'if [[ $out =~ "SUCCESS" ]]; then exit 0; ' \
        'elif [[ $out =~ "FAIL" ]]; then exit 11; else exit 99; fi'.freeze

      # Seconds to wait after boot before probing for a running cloud-init.
      CLOUD_INIT_STARTUP_GRACE = 5

      default_config(:opennebula_endpoint) do
        ENV.fetch("ONE_XMLRPC", "http://127.0.0.1:2633/RPC2")
      end

      default_config(:oneauth_file) do
        one_auth = ENV["ONE_AUTH"]
        if one_auth.nil? || one_auth.empty?
          File.join(Dir.home, ".one", "one_auth")
        else
          one_auth
        end
      end

      # Filenames searched, in order, when `public_key_path` is not set.
      PUBLIC_KEY_CANDIDATES = %w{
        id_rsa.pub
        id_dsa.pub
        identity.pub
        id_ecdsa.pub
        id_ed25519.pub
      }.freeze

      default_config :vm_hostname, &:default_vm_hostname

      default_config :public_key_path do
        PUBLIC_KEY_CANDIDATES
          .map { |name| File.expand_path("~/.ssh/#{name}") }
          .find { |path| File.exist?(path) }
      end

      default_config :username, "local"
      default_config :memory, 512
      default_config :vcpu, 1
      default_config :cpu, 1
      default_config :user_variables, {}
      default_config :context_variables, {}

      default_config :wait_for, 600
      default_config :no_ssh_tcp_check, false
      default_config :no_ssh_tcp_check_sleep, 120
      default_config :no_passwordless_sudo_check, false
      default_config :no_passwordless_sudo_sleep, 120
      default_config :no_cloud_init_check, false
      default_config :passwordless_sudo_timeout, 300
      default_config :passwordless_sudo_retry_interval, 10
      default_config :cloud_init_timeout, 600
      default_config :cloud_init_retry_interval, 10

      # Creates an OpenNebula VM for this instance and blocks until it is ready
      # to be converged.
      #
      # The method is idempotent: if `state` already carries a `:vm_id` that
      # still resolves to a VM in OpenNebula, no new VM is created.
      #
      # @param state [Hash] mutable instance state; populated with `:vm_id`,
      #   `:hostname` and `:username` on success
      # @return [void]
      # @raise [Kitchen::UserError] if the template configuration is invalid or
      #   the configured public key cannot be read
      # @raise [Kitchen::ActionFailed] if OpenNebula credentials are missing or
      #   the instance never becomes ready
      def create(state)
        super

        conn = opennebula_connect

        # Ensure we can authenticate with OpenNebula.
        rc = conn.client.get_version
        raise ActionFailed, rc.message if OpenNebula.is_error?(rc)

        if vm_exists?(conn, state[:vm_id])
          info("OpenNebula instance #{instance.to_str} already created.")
          return
        end

        newvm = conn.servers.new
        newvm.flavor = find_flavor(conn)
        newvm.name = config[:vm_hostname]

        apply_user_variables(newvm.flavor)
        apply_context(newvm.flavor)
        apply_sizing(newvm.flavor)

        # TODO: Set up NIC and disk if not specified in template
        vm = newvm.save
        vm.wait_for { ready? }

        state[:vm_id] = vm.id
        state[:hostname] = vm.ip
        state[:username] = config[:username]

        tcp_check(state)
        passwordless_sudo_check(state)
        wait_for_cloud_init(state) if cloud_init_check(state)
        info("OpenNebula instance #{instance.to_str} created.")
      end

      # Destroys the OpenNebula VM tracked in `state`, if there is one.
      #
      # @param state [Hash] mutable instance state; `:vm_id` is cleared on
      #   success
      # @return [void]
      # @raise [Kitchen::ActionFailed] if OpenNebula credentials are missing
      def destroy(state)
        return if state[:vm_id].nil?

        opennebula_connect.servers.destroy(state[:vm_id])
        info("OpenNebula instance #{instance.to_str} destroyed.")
        state.delete(:vm_id)
        state.delete(:hostname)
      end

      # Waits for the instance's transport to accept connections.
      #
      # When `no_ssh_tcp_check` is set the readiness probe is replaced by a
      # flat sleep of `no_ssh_tcp_check_sleep` seconds.
      #
      # @param state [Hash] instance state, used to build the connection
      # @return [void]
      def tcp_check(state)
        if config[:no_ssh_tcp_check]
          sleep(config[:no_ssh_tcp_check_sleep])
        else
          instance.transport.connection(state).wait_until_ready
        end
        debug("SSH ready on #{instance.to_str}")
      end

      # Ensures the login user has passwordless sudo on the guest.
      #
      # When `no_passwordless_sudo_check` is set the probe is replaced by a
      # flat sleep of `no_passwordless_sudo_sleep` seconds.
      #
      # @param state [Hash] instance state, used to build the connection
      # @return [void]
      # @raise [Kitchen::ActionFailed] if sudo never becomes passwordless
      def passwordless_sudo_check(state)
        if config[:no_passwordless_sudo_check]
          sleep(config[:no_passwordless_sudo_sleep])
        else
          wait_for_passwordless_sudo(state)
        end
        debug("Passwordless sudo ready on #{instance.to_str}")
      end

      # Polls the guest until `sudo -n true` succeeds.
      #
      # @param state [Hash] instance state, used to build the connection
      # @return [void]
      # @raise [Kitchen::ActionFailed] if `passwordless_sudo_timeout` seconds
      #   elapse, or if the connection fails for any reason other than sudo
      #   prompting for a password
      def wait_for_passwordless_sudo(state)
        started = monotonic_time
        timeout = config[:passwordless_sudo_timeout]
        retry_interval = config[:passwordless_sudo_retry_interval]

        begin
          instance.transport.connection(state) do |conn|
            conn.execute(SUDO_PROBE_COMMAND)
          end
        rescue Kitchen::Transport::SshFailed => e
          raise ActionFailed, e.message unless ssh_exit_status(e) == 1

          elapsed = monotonic_time - started
          if elapsed > timeout
            raise ActionFailed,
              "Passwordless sudo was not ready on #{instance.to_str} after #{timeout} seconds"
          end

          info("Probing for passwordless sudo ready on #{instance.to_str}, " \
               "elapsed #{elapsed.round}/#{timeout} secs")
          sleep retry_interval
          retry
        end
      end

      # Detects whether cloud-init is running on the guest.
      #
      # @param state [Hash] instance state, used to build the connection
      # @return [Boolean] true when cloud-init is running and should be waited
      #   on, false when it is absent or the check is disabled
      def cloud_init_check(state)
        return false if config[:no_cloud_init_check]

        sleep CLOUD_INIT_STARTUP_GRACE # allow cloud-init to start
        begin
          instance.transport.connection(state) do |conn|
            info("Probing for cloud-init running on #{instance.to_str} ...")
            conn.execute(CLOUD_INIT_RUNNING_COMMAND)
          end
          info("Cloud-init is running on #{instance.to_str}")
          true
        rescue Kitchen::Transport::TransportFailed
          info("Cloud-init not running on #{instance.to_str}")
          false
        end
      end

      # Polls the guest until cloud-init reports successful completion.
      #
      # @param state [Hash] instance state, used to build the connection
      # @return [void]
      # @raise [Kitchen::ActionFailed] if cloud-init reports a failure,
      #   `cloud_init_timeout` seconds elapse, or the connection fails
      def wait_for_cloud_init(state)
        started = monotonic_time
        timeout = config[:cloud_init_timeout]
        retry_interval = config[:cloud_init_retry_interval]

        begin
          instance.transport.connection(state) do |conn|
            conn.execute(CLOUD_INIT_WAIT_COMMAND)
          end
          info("Cloud-init finished successfully on #{instance.to_str}")
        rescue Kitchen::Transport::SshFailed => e
          case ssh_exit_status(e)
          when CLOUD_INIT_FAILED_EXIT
            error("Cloud-init failed on #{instance.to_str}")
            raise ActionFailed, "Cloud-init failed on #{instance.to_str}: #{e.message}"
          when CLOUD_INIT_PENDING_EXIT
            elapsed = monotonic_time - started
            if elapsed > timeout
              raise ActionFailed,
                "Cloud-init did not finish on #{instance.to_str} after #{timeout} seconds"
            end

            info("Probing for cloud-init successful completion on #{instance.to_str}, " \
                 "elapsed #{elapsed.round}/#{timeout} secs")
            sleep retry_interval
            retry
          else
            raise ActionFailed, e.message
          end
        end
      end

      # Generates the random suffix appended to a generated VM hostname.
      #
      # @return [String] a lowercase alphanumeric string of
      #   {HOSTNAME_SUFFIX_LENGTH} characters
      def self.random_hostname_suffix
        Array.new(HOSTNAME_SUFFIX_LENGTH) { HOSTNAME_CHARS.sample }.join
      end

      # The default hostname for this instance's VM: the Test Kitchen instance
      # name plus a random suffix, so that several runs of the same suite can
      # coexist in one OpenNebula cloud.
      #
      # Memoized because Test Kitchen re-evaluates `default_config` blocks on
      # every configuration read -- without this the hostname would differ each
      # time it was looked up.
      #
      # @return [String] the generated hostname
      def default_vm_hostname
        @default_vm_hostname ||= "#{instance.name}-#{self.class.random_hostname_suffix}"
      end

      private

      # Builds an authenticated connection to the OpenNebula XML-RPC API and
      # applies the configured `wait_for` timeout to Fog's global blocking
      # helpers.
      #
      # @return [Fog::Compute::OpenNebula] an OpenNebula compute service
      # @raise [Kitchen::ActionFailed] if credentials cannot be located or are
      #   not in `username:password` form
      def opennebula_connect
        Fog.timeout = config[:wait_for].to_i

        username, password = opennebula_credentials
        Fog::Compute.new(
          provider: "OpenNebula",
          opennebula_username: username,
          opennebula_password: password,
          opennebula_endpoint: config[:opennebula_endpoint]
        )
      end

      # Resolves the OpenNebula username and password.
      #
      # `ONE_AUTH` is honoured first and may hold either a path to a
      # credentials file or the literal `username:password` pair. Otherwise the
      # file named by the `oneauth_file` config is read.
      #
      # @return [Array(String, String)] the username and password
      # @raise [Kitchen::ActionFailed] if no credentials source exists or the
      #   credentials are not in `username:password` form
      def opennebula_credentials
        raw = raw_credentials.strip
        username, password = raw.split(":", 2)

        if username.nil? || username.empty? || password.nil? || password.empty?
          raise ActionFailed,
            "OpenNebula credentials must be in 'username:password' form"
        end

        [username, password]
      end

      # Reads the unparsed credentials string from `ONE_AUTH` or the
      # `oneauth_file` config.
      #
      # @return [String] the raw credentials string
      # @raise [Kitchen::ActionFailed] if no credentials source exists
      def raw_credentials
        one_auth = ENV["ONE_AUTH"]
        if one_auth && !one_auth.empty?
          File.exist?(one_auth) ? File.read(one_auth) : one_auth
        elsif File.exist?(config[:oneauth_file])
          File.read(config[:oneauth_file])
        else
          raise ActionFailed, "Could not find one_auth file #{config[:oneauth_file]}"
        end
      end

      # Checks whether a previously recorded VM still exists in OpenNebula.
      #
      # @param conn [Fog::Compute::OpenNebula] an OpenNebula compute service
      # @param vm_id [Integer, String, nil] the recorded VM id
      # @return [Boolean] true when `vm_id` is set and still resolves
      def vm_exists?(conn, vm_id)
        return false if vm_id.nil?

        !conn.list_vms({ id: vm_id }).empty?
      end

      # Resolves the OpenNebula template (Fog flavor) the VM is built from.
      #
      # @param conn [Fog::Compute::OpenNebula] an OpenNebula compute service
      # @return [Fog::Compute::OpenNebula::Flavor] the matched template
      # @raise [Kitchen::UserError] if the template configuration is invalid or
      #   does not resolve to exactly one template
      def find_flavor(conn)
        validate_template_config!

        flavor =
          if config[:template_id]
            conn.flavors.get(config[:template_id])
          else
            flavors_by_name(conn)
          end

        if flavor.nil?
          raise UserError,
            "Could not find template to create VM. -- Verify your template filters and one_auth credentials"
        end

        flavor
      end

      # Ensures exactly one of `template_id` and `template_name` is configured.
      #
      # @return [void]
      # @raise [Kitchen::UserError] if neither or both are set
      def validate_template_config!
        if config[:template_id].nil? && config[:template_name].nil?
          raise UserError, "template_name or template_id not specified in .kitchen.yml"
        elsif !config[:template_id].nil? && !config[:template_name].nil?
          raise UserError, "Only one of template_name or template_id should be specified in .kitchen.yml"
        end
      end

      # Looks a template up by name, optionally narrowed by owner.
      #
      # @param conn [Fog::Compute::OpenNebula] an OpenNebula compute service
      # @return [Fog::Compute::OpenNebula::Flavor, nil] the single matching
      #   template, or nil when nothing matched
      # @raise [Kitchen::UserError] if the filter matches more than one
      #   template
      def flavors_by_name(conn)
        filter = {
          name: config[:template_name],
          uname: config[:template_uname],
          uid: config[:template_uid],
        }
        matches = conn.flavors.get_by_filter(filter)
        return nil if matches.nil? || matches.empty?

        if matches.length > 1
          raise UserError, "More than one template found.  Please restrict using template_uname"
        end

        matches.first
      end

      # Merges the configured `user_variables` into the template's user
      # template section.
      #
      # @param flavor [Fog::Compute::OpenNebula::Flavor] the template to mutate
      # @return [void]
      def apply_user_variables(flavor)
        flavor.user_variables = {} if blank_section?(flavor.user_variables)
        config[:user_variables].each do |key, val|
          flavor.user_variables[key.to_s] = val
        end
      end

      # Injects the SSH public key and Test Kitchen markers into the template's
      # `CONTEXT` section, then merges the configured `context_variables`.
      #
      # @param flavor [Fog::Compute::OpenNebula::Flavor] the template to mutate
      # @return [void]
      # @raise [Kitchen::UserError] if the public key cannot be read
      def apply_context(flavor)
        flavor.context = {} if blank_section?(flavor.context)
        flavor.context["SSH_PUBLIC_KEY"] = public_key
        flavor.context["TEST_KITCHEN"] = "YES"
        # Support for overriding context variables in the VM template
        config[:context_variables].each do |key, val|
          flavor.context[key.to_s] = val
        end
      end

      # Applies the configured sizing to the template.
      #
      # @param flavor [Fog::Compute::OpenNebula::Flavor] the template to mutate
      # @return [void]
      def apply_sizing(flavor)
        flavor.memory = config[:memory]
        flavor.vcpu = config[:vcpu]
        flavor.cpu = config[:cpu]
      end

      # Reads the SSH public key that will be pushed into the guest.
      #
      # @return [String] the public key with trailing whitespace removed
      # @raise [Kitchen::UserError] if no public key was found or the
      #   configured path is unreadable
      def public_key
        path = config[:public_key_path]
        if path.nil?
          raise UserError,
            "Could not find an SSH public key. Set public_key_path in .kitchen.yml."
        end
        unless File.exist?(path)
          raise UserError, "Could not read SSH public key #{path}"
        end

        File.read(path).chomp
      end

      # Reports whether a template section is unset and should be replaced with
      # an empty Hash before variables are merged into it.
      #
      # @param section [Object, nil] a template section as returned by Fog
      # @return [Boolean] true when the section holds nothing usable
      def blank_section?(section)
        section.nil? || section.empty?
      end

      # Extracts the remote exit status from a Test Kitchen SSH failure.
      #
      # @param error [Kitchen::Transport::SshFailed] the raised failure
      # @return [Integer, nil] the exit status, or nil when the message does
      #   not carry one
      def ssh_exit_status(error)
        match = error.message.match(/SSH exited \((\d+)\)/)
        match && match[1].to_i
      end

      # Returns a clock reading that is immune to wall-clock adjustments.
      #
      # @return [Float] seconds from an arbitrary monotonic epoch
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
