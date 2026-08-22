# Helpers for wiring a driver into a genuine Kitchen::Instance.
module KitchenHelpers
  # Captures everything the driver logs during an example.
  #
  # @return [StringIO] the log sink
  def log_output
    @log_output ||= StringIO.new
  end

  # The text the driver has logged so far.
  #
  # @return [String] captured log output
  def logged
    log_output.string
  end

  # A Kitchen logger that writes into {#log_output}.
  #
  # @return [Kitchen::Logger]
  def kitchen_logger
    @kitchen_logger ||= Kitchen::Logger.new(stdout: log_output, level: :debug, colorize: false)
  end

  # Builds a real Kitchen::Instance around the given driver. Constructing the
  # instance is what calls `finalize_config!`, so the driver is fully wired
  # afterwards and `driver.instance` is populated.
  #
  # @param driver [Kitchen::Driver::Base] the driver under test
  # @param suite [String] suite name
  # @param platform [String] platform name
  # @param transport [Kitchen::Transport::Base] transport to expose to the driver
  # @return [Kitchen::Instance] the wired instance
  def kitchen_instance(driver, suite: "default", platform: "ubuntu-24.04", transport: nil)
    state_file = Kitchen::StateFile.new(Dir.tmpdir, "#{suite}-#{platform}")
    Kitchen::Instance.new(
      driver: driver,
      logger: kitchen_logger,
      suite: Kitchen::Suite.new(name: suite),
      platform: Kitchen::Platform.new(name: platform),
      provisioner: Kitchen::Provisioner::Dummy.new,
      transport: transport || Kitchen::Transport::Dummy.new,
      verifier: Kitchen::Verifier::Dummy.new,
      lifecycle_hooks: Kitchen::LifecycleHooks.new({}, state_file),
      state_file: state_file
    )
  end

  # Builds a Kitchen SSH failure carrying the given remote exit status, in the
  # exact shape `Kitchen::Transport::Ssh` produces.
  #
  # @param status [Integer] the remote exit status
  # @param command [String] the command that failed
  # @return [Kitchen::Transport::SshFailed]
  def ssh_failure(status, command)
    Kitchen::Transport::SshFailed.new("SSH exited (#{status}) for command: [#{command}]")
  end
end
