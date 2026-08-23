## Unreleased

### Fixed

* `converge` and `verify` called `super`, but `Kitchen::Driver::Base` defines neither -- both raised `NoMethodError`
  when called. They were no-ops by intent (converging and verifying belong to the provisioner and verifier), so they
  have been removed.
* `create` never called `super`, so the `pre_create_command` setting every driver inherits from Test Kitchen was
  silently ignored.
* `opennebula_endpoint` and `oneauth_file` read `ONE_XMLRPC` / `ONE_AUTH` when the driver file was *loaded* rather
  than when the setting was read, so environment variables exported after Test Kitchen started were ignored. They are
  now evaluated lazily, per instance.
* `vm_hostname` generated a new random suffix on every read, so `kitchen diagnose` reported a hostname the VM never
  had. The generated name is now memoized per instance.
* `kitchen destroy` on an instance that was never created called `servers.destroy(nil)`. It is now a no-op that does
  not even open a connection, and a successful destroy clears `vm_id` and `hostname` from the state.
* Credentials were split on every `:`, truncating any password containing a colon, and the trailing newline of
  `~/.one/one_auth` was passed through as part of the password. Credentials are now stripped and split once.
  Malformed credentials produce a clear error instead of a confusing authentication failure.
* An empty `ONE_AUTH` produced the error "Could not find one_auth file" with a blank path. It is now treated as unset.
* The driver referenced `Kitchen::Transport::SshFailed` in its `rescue` clauses without requiring the SSH transport.
  With any other transport configured, the rescue itself raised `NameError` and masked the real error.
* Timeouts were measured with `Time.now`, so an NTP or DST adjustment mid-run could extend or cut short a wait. They
  now use a monotonic clock.
* The passwordless sudo and cloud-init probes logged elapsed time as "time left", and on timeout raised the raw SSH
  error rather than saying the wait had timed out.
* The passwordless sudo retry matched the failure by exact string comparison against one hard-coded message; it now
  matches on the remote exit status.
* A missing or unreadable `public_key_path` reached `File.read(nil)` and raised `TypeError`. It now raises a
  `Kitchen::UserError` naming the problem.
* Template misconfiguration now raises `Kitchen::UserError`, which Test Kitchen reports as a user-facing message,
  instead of a bare `RuntimeError` with a stack trace.

### Added

* A full RSpec unit test suite with 100% line and branch coverage of `lib/`, enforced by SimpleCov.
* YARD documentation for every module, class, constant and method.
* `~/.ssh/id_ed25519.pub` is now searched when discovering a default `public_key_path`.
* The driver declares `kitchen_driver_api_version 2`.
* README documentation for the `vcpu` and `cpu` settings, which were implemented but undocumented.

## [0.3.0](https://github.com/test-kitchen/kitchen-opennebula/compare/kitchen-opennebula-v0.2.3...kitchen-opennebula/v0.3.0) (2026-08-23)


### Bug Fixes

* bump tk dep to allow tk 4 ([#36](https://github.com/test-kitchen/kitchen-opennebula/issues/36)) ([5aa2aa2](https://github.com/test-kitchen/kitchen-opennebula/commit/5aa2aa20a398a13d5fe09350231f76a57e3984ff))
* correct release-please manifest to last published version ([#44](https://github.com/test-kitchen/kitchen-opennebula/issues/44)) ([e04145b](https://github.com/test-kitchen/kitchen-opennebula/commit/e04145b1873daab56d14d646824dc5d8a55d61e8))

## 0.3.0

* fix endless loop in passwordless sudo check
* wait for cloud-init to complete successfully

## 0.2.3

* add random string to instance name
* allow specifying cpu for box
* use documented ONE_AUTH key
* keep lower bound of requirement to '>= 4.10'

## 0.2.2

* Restrict opennebula gem dependency version to be '~> 4.10', '< 5'.

## 0.2.1

* Do not use methods from Kitchen::SSHBase as we are no longer inherit them. Rely on instance.transport instead.

## 0.2.0

* Switch SSH api to use gateway-enabled wrapper, instead of raw Kitchen::SSH, which does not support ssh gateways.

## 0.1.2

* Adds an authentication check for OpenNebula, and uses a later version of fog which supports multiple NICs in a VM template.

## 0.1.0

* Initial release
