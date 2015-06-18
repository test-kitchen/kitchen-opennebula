# -*- encoding: utf-8 -*-
#
# Author:: Andrew J. Brown (<anbrown@blackberry.com>)
#
# Copyright (C) 2014, BlackBerry, Ltd.
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
    # @author Andrew J. Brown <anbrown@blackberry.com>
    class Opennebula < Kitchen::Driver::SSHBase
      default_config :opennebula_endpoint,
        ENV.fetch('ONE_XMLRPC', 'http://127.0.0.1:2633/RPC2')

      default_config :oneauth_file,
        ENV.fetch('ONE_AUTH', "#{ENV['HOME']}/.one/one_auth")

      default_config :vm_hostname do |driver|
        "#{driver.instance.name}"
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
      default_config :user_variables, { }
      default_config :context_variables, { }

      default_config :wait_for, 600
      default_config :no_ssh_tcp_check, false
      default_config :no_ssh_tcp_check_sleep, 120
      default_config :no_passwordless_sudo_check, false
      default_config :no_passwordless_sudo_sleep, 120
      
      def initialize(config)
        super
        Fog.timeout = config[:wait_for].to_i
      end

      def create(state)
        conn = opennebula_connect

        # Check for servers from connection to help debug possible connection issues
        if conn.servers.length == 0
          info("Connection has returned zero servers.")
        end

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
       
        # TODO: Set up NIC and disk if not specified in template
        vm = newvm.save
        vm.wait_for { ready? }
        state[:vm_id] = vm.id
        state[:hostname] = vm.ip
        state[:username] = config[:username]
        tcp_check(state)
        passwordless_sudo_check(state)
        info("OpenNebula instance #{instance.to_str} created.")
      end

      def tcp_check(state)
        wait_for_sshd(state[:hostname]) unless config[:no_ssh_tcp_check]
        sleep(config[:no_ssh_tcp_check_sleep]) if config[:no_ssh_tcp_check]
        debug("SSH ready on #{instance.to_str}")
      end
      
      def passwordless_sudo_check(state)
        wait_for_passwordless_sudo(state) unless config[:no_passwordless_sudo_check]
        sleep(config[:no_passwordless_sudo_sleep]) if config[:no_passwordless_sudo_check]
        debug("Passwordless sudo ready on #{instance.to_str}")
      end
      
      def wait_for_passwordless_sudo(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          retries = config[:passwordless_sudo_timeout] || 300
          retry_interval = config[:passwordless_sudo_retry_interval] || 10
          begin
            logger.info("Waiting #{retries.to_s} seconds for #{config[:username]} user to be granted passwordless sudo on #{state[:hostname]}...")
            retries -= retry_interval
            run_remote("sudo -n true", conn)
          rescue ActionFailed => e
            if (e.message.eql? "SSH exited (1) for command: [sudo -n true]") && (retries >= 0)
              sleep retry_interval
              retry
            end
            raise ActionFailed, e.message
          end        
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
        if File.exists?(config[:oneauth_file])
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