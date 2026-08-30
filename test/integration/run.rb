# Drives the Test Kitchen integration suites in kitchen.yml against the fake
# OpenNebula daemon in test/support/fake_opennebula.rb.
#
# It starts the daemon, points the environment at it exactly as a user would
# point Test Kitchen at a real cloud, runs the full create/converge/verify/
# destroy cycle for every suite, and then checks the paths a passing suite
# cannot reach: the doctor hook, destroying an instance that was never created,
# and credentials OpenNebula rejects.
#
# Run it with `bundle exec rake integration`.

require "socket"
require "tmpdir"

# The credentials the fake daemon accepts. Kept in step with FakeOpennebula.
CREDENTIALS = "oneadmin:opennebula".freeze

# A public key of the shape OpenNebula contextualization expects. Nothing ever
# authenticates with it -- the suites use Test Kitchen's dummy transport -- so
# it is written at run time rather than committed.
PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI#{"A" * 22} kitchen-integration".freeze

# The repository root, which is also the Test Kitchen project root.
ROOT = File.expand_path("../..", __dir__)

# Fails the run with a message.
#
# @param message [String] what went wrong
# @return [void]
def die(message)
  warn("\n!!! #{message}")
  exit(1)
end

# Runs a Test Kitchen command.
#
# @param args [Array<String>] arguments to `kitchen`
# @return [Array(String, Boolean)] its combined output, and whether it passed
def kitchen(*args)
  puts("\n==> kitchen #{args.join(" ")}")
  output = IO.popen([Gem.ruby, "-S", "kitchen", *args], chdir: ROOT, err: %i{child out}, &:read)
  puts(output)
  [output, $?.success?]
end

# Runs a Test Kitchen command that has to pass.
#
# @param args [Array<String>] arguments to `kitchen`
# @return [String] its output
def kitchen!(*args)
  output, ok = kitchen(*args)
  die("kitchen #{args.join(" ")} failed") unless ok
  output
end

# Runs a Test Kitchen command that has to fail, for the stated reason.
#
# Test Kitchen prints only a summary on failure and sends the driver's own
# message to the instance log, so both are searched.
#
# @param args [Array<String>] arguments to `kitchen`
# @param expecting [String] text the failure has to mention
# @return [void]
def kitchen_fails!(*args, expecting:)
  output, ok = kitchen(*args)
  die("kitchen #{args.join(" ")} unexpectedly passed") if ok
  return if output.include?(expecting) || kitchen_logs.include?(expecting)

  die("kitchen #{args.join(" ")} failed, but without mentioning #{expecting.inspect}")
end

# @return [String] everything Test Kitchen has logged during this run
def kitchen_logs
  Dir[File.join(ROOT, ".kitchen", "logs", "*.log")].map { |log| File.read(log) }.join
end

# Blocks until the fake daemon is accepting connections.
#
# @param port [Integer] the port it was told to listen on
# @param pid [Integer] the daemon's process id
# @return [void]
def wait_for_daemon(port, pid)
  30.times do
    die("the fake OpenNebula daemon exited before it was ready") if Process.waitpid(pid, Process::WNOHANG)

    begin
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue ::SystemCallError
      sleep 0.2
    end
  end
  die("the fake OpenNebula daemon never came up on port #{port}")
end

port = Integer(ENV.fetch("ONE_PORT", "12633"))

Dir.mktmpdir("kitchen-opennebula-integration") do |dir|
  auth_file = File.join(dir, "one_auth")
  key_file = File.join(dir, "kitchen.pub")
  File.write(auth_file, "#{CREDENTIALS}\n")
  File.write(key_file, "#{PUBLIC_KEY}\n")

  # Exactly what a user exports to point Test Kitchen at a real cloud.
  ENV["ONE_XMLRPC"] = "http://127.0.0.1:#{port}/RPC2"
  ENV["ONE_AUTH"] = auth_file
  ENV["KITCHEN_OPENNEBULA_PUBLIC_KEY"] = key_file

  daemon = spawn({ "ONE_PORT" => port.to_s },
    Gem.ruby, File.join(ROOT, "test", "support", "fake_opennebula.rb"))
  begin
    wait_for_daemon(port, daemon)

    # The whole lifecycle, for every suite.
    kitchen!("test", "--destroy=always")

    # The doctor hook, on a configuration it should be happy with.
    kitchen!("doctor", "template-by-id-fake")

    # Destroying an instance that was never created is a no-op, not a failure.
    kitchen!("destroy", "all")

    # Credentials OpenNebula rejects surface OpenNebula's own message.
    ENV["ONE_AUTH"] = "wrong:credentials"
    kitchen_fails!("create", "template-by-id-fake",
      expecting: "User couldn't be authenticated")
  ensure
    Process.kill("TERM", daemon)
    Process.waitpid(daemon)
  end
end

puts("\nIntegration suites passed.")
