# Helpers for temporarily overriding process environment variables.
module EnvHelpers
  # The temporary HOME directory assigned to the running example.
  #
  # @return [String] path to the sandboxed home directory
  attr_reader :sandbox_home

  # Runs a block with the given environment variables applied, restoring the
  # previous values afterwards. A nil value deletes the variable.
  #
  # @param vars [Hash{String => String, nil}] variables to apply
  # @return [Object] the block's return value
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Writes a file underneath the example's sandboxed HOME.
  #
  # @param relative_path [String] path relative to HOME
  # @param contents [String] file contents
  # @return [String] the absolute path that was written
  def write_home_file(relative_path, contents)
    path = File.join(sandbox_home, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end
end
