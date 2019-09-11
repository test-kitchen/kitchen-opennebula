# -*- encoding: utf-8 -*-
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

require 'fog'
require 'kitchen'

module Kitchen

  module Driver

    # Opennebula driver for Kitchen.
    #
    class Opennebula < Kitchen::Driver::Base
      default_config :opennebula_endpoint,
        ENV.fetch('ONE_XMLRPC', 'http://127.0.0.1:2633/RPC2')

      default_config :oneauth_file,
        ENV.fetch('ONE_AUTH', "#{ENV['HOME']}/.one/one_auth")

      default_config :vm_hostname do |driver|
        randstr = 8.times.collect{[*'a'..'z',*('0'..'9')].sample}.join
        "#{driver.instance.name}-#{randstr}"
      end

      default_config :public_key_path do
        [
          File.expand_path('~/.ssh/id_rsa.pub'),
          File.expand_path('~/.ssh/id_dsa.pub'),
          File.expand_path('~/.ssh/identity.pub'),
          File.expand_path('~/.ssh/id_ecdsa.pub')
        ].find { |path| File.exist?(path) }
      end

      default_config :username, 'local'
      default_config :memory, 512
      default_config :vcpu, 1
      default_config :cpu, 1
      default_config :user_variables, { }
      default_config :context_variables, { }

      default_config :wait_for, 600
      default_config :no_ssh_tcp_check, false
      default_config :no_ssh_tcp_check_sleep, 120
      default_config :no_passwordless_sudo_check, false
      default_config :no_passwordless_sudo_sleep, 120
      default_config :no_cloud_init_check, false

      def initialize(config)
        super
        Fog.timeout = config[:wait_for].to_i
      end

      def create(state)
        conn = opennebula_connect

        # Ensure we can authenticate with OpenNebula
        rc = conn.client.get_version
        raise(rc.message) if OpenNebula.is_error?(rc)

        # Check if VM is already created.
        if state[:vm_id] && !conn.list_vms({:id => state[:vm_id]}).empty?
          info("OpenNebula instance #{instance.to_str} already created.")
          return
        end

        if config[:template_id].nil? and config[:template_name].nil?
          raise "template_name or template_id not specified in .kitchen.yml"
        elsif !config[:template_id].nil? and !config[:template_name].nil?
          raise "Only one of template_name or template_id should be specified in .kitchen.yml"
        end

        newvm = conn.servers.new
        if config[:template_id]
          newvm.flavor = conn.flavors.get config[:template_id]
        elsif config[:template_name]
          filter = {
            :name  => config[:template_name],
            :uname => config[:template_uname],
            :uid   => config[:template_uid]
          }
          newvm.flavor = conn.flavors.get_by_filter filter
          if !newvm.flavor.nil? and newvm.flavor.length > 1
            raise 'More than one template found.  Please restrict using template_uname'
          end
          newvm.flavor = newvm.flavor.first unless newvm.flavor.nil?
        end
        if newvm.flavor.nil?
          raise "Could not find template to create VM. -- Verify your template filters and one_auth credentials"
        end
        newvm.name = config[:vm_hostname]

        newvm.flavor.user_variables = {} if newvm.flavor.user_variables.nil? || newvm.flavor.user_variables.empty?
        config[:user_variables].each do |key, val|
          newvm.flavor.user_variables[key.to_s] = val
        end

        newvm.flavor.context = {} if newvm.flavor.context.nil? || newvm.flavor.context.empty?
        newvm.flavor.context['SSH_PUBLIC_KEY'] = File.read(config[:public_key_path]).chomp
        newvm.flavor.context['TEST_KITCHEN'] = "YES"
        # Support for overriding context variables in the VM template
        config[:context_variables].each do |key, val|
          newvm.flavor.context[key.to_s] = val
        end
        newvm.flavor.memory = config[:memory]
        newvm.flavor.vcpu = config[:vcpu]
        newvm.flavor.cpu = config[:cpu]

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

      def tcp_check(state)
        instance.transport.connection(state).wait_until_ready unless config[:no_ssh_tcp_check]
        sleep(config[:no_ssh_tcp_check_sleep]) if config[:no_ssh_tcp_check]
        debug("SSH ready on #{instance.to_str}")
      end

      def passwordless_sudo_check(state)
        if config[:no_passwordless_sudo_check]
          sleep(config[:no_passwordless_sudo_sleep])
        else
          wait_for_passwordless_sudo(state)
        end
        debug("Passwordless sudo ready on #{instance.to_str}")
      end

      def wait_for_passwordless_sudo(state)
        started = Time.now
        timeout = config[:passwordless_sudo_timeout] || 300
        retry_interval = config[:passwordless_sudo_retry_interval] || 10
        begin
          instance.transport.connection(state) do |conn|
            conn.execute('sudo -n true > /dev/null 2>&1')
          end
        rescue Kitchen::Transport::SshFailed => e
          duration = ((Time.now - started) * 1000).ceil/1000.to_i
          if (e.message.eql? "SSH exited (1) for command: [sudo -n true > /dev/null 2>&1]") && (duration <= timeout)
            info("Probing for passwordless sudo ready on #{instance.to_str}, time left #{duration}/#{timeout} secs")
            sleep retry_interval
            retry
          end
          raise ActionFailed, e.message
        end
      end

      def cloud_init_check(state)
        return false if config[:no_cloud_init_check]
        sleep 5 # allow cloud-init to start
        begin
          instance.transport.connection(state) do |conn|
            info("Probing for cloud-init running on #{instance.to_str} ...")
            conn.execute('ps -ef | grep cloud-init | grep -v grep >/dev/null 2>&1; exit $?')
          end
          info("Cloud-init is running on #{instance.to_str}")
          return true
        rescue
          info("Cloud-init not running on #{instance.to_str}")
          return false
        end
      end

      def wait_for_cloud_init(state)
        started = Time.now
        timeout = config[:cloud_init_timeout] || 600
        retry_interval = config[:cloud_init_retry_interval] || 10
        cmd = 'out=$(cloud-init analyze dump| awk "/running modules for final/{nr[NR+4]; next}; NR in nr"); \
if [[ $out =~ "SUCCESS" ]]; then exit 0; elif [[ $out =~ "FAIL" ]]; then exit 11; else exit 99; fi'
        begin
          instance.transport.connection(state) do |conn|
            conn.execute(cmd)
          end
        rescue Kitchen::Transport::SshFailed => e
          duration = ((Time.now - started) * 1000).ceil/1000.to_i
          if (e.message.match(/SSH exited \(11\) for command: \[out=\$\(cloud-init analyze dump/)) && (duration <= timeout)
            error("Cloud-init failed on #{instance.to_str}")
          elsif (e.message.match(/SSH exited \(99\) for command: \[out=\$\(cloud-init analyze dump/)) && (duration <= timeout)
            info("Probing for cloud-init successful completion on #{instance.to_str}, time left #{duration}/#{timeout} secs")
            sleep retry_interval
            retry
          end
          raise ActionFailed, e.message
        end
      end

      def converge(state)
        super
      end

      def verify(state)
        super
      end

      def destroy(state)
        conn = opennebula_connect
        conn.servers.destroy(state[:vm_id])
      end

      protected

      def opennebula_connect()
        opennebula_creds = nil
        if ENV.has_key?('ONE_AUTH')
          if File.exist?(ENV['ONE_AUTH'])
            opennebula_creds = File.read(ENV['ONE_AUTH'])
          else
            opennebula_creds = ENV['ONE_AUTH']
          end
        elsif File.exist?(config[:oneauth_file])
          opennebula_creds = File.read(config[:oneauth_file])
        else
          raise ActionFailed, "Could not find one_auth file #{config[:oneauth_file]}"
        end
        opennebula_username = opennebula_creds.split(':')[0]
        opennebula_password = opennebula_creds.split(':')[1]
        conn = Fog::Compute.new( {
          :provider => 'OpenNebula',
          :opennebula_username => opennebula_username,
          :opennebula_password => opennebula_password,
          :opennebula_endpoint => config[:opennebula_endpoint]
        } )
        conn
      end
    end
  end
end
