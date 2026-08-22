# Kitchen::Opennebula

[![Gem Version](https://badge.fury.io/rb/kitchen-opennebula.svg)](https://badge.fury.io/rb/kitchen-opennebula)

A Test Kitchen Driver for Opennebula.

## Requirements

This driver talks to OpenNebula's XML-RPC API through [fog-opennebula](https://github.com/fog/fog-opennebula) and
requires Ruby 3.1 or later.

## Installation and Setup

1. Download and install latest [ChefDK](https://downloads.chef.io/tools/workstation).
2. Please add bin locations to your PATH:

   - `C:\opscode\chefdk\bin;C:\opscode\chefdk\embedded\bin\` (windows)
   - `/opt/chefdk/bin/:/opt/chefdk/embedded/bin` (unix)

3. Reopen console or reload your env PATH
4. Run following command:
    gem install kitchen-opennebula --no-user-install --no-ri --no-rdoc

Please read the [config_yml_kitchen](https://kitchen.ci/docs/reference/) page for more details.

## Virtual Machine Requirements

This driver requires an OpenNebula OS image that conforms to a number of requirements

* The VM puts the ssh key defined in the SSH\_PUBLIC\_KEY context variable into `$HOME/.ssh/authorized_keys`
* The VM ensures the user has passwordless sudo access

## Configuration

### opennebula\_endpoint

URL where the OpenNebula daemon is listening. The default value is taken from the ONE\_XMLRPC environment variable,
or `http://127.0.0.1:2633/RPC2` if unset.

### oneauth\_file

Path to the file containing OpenNebula authentication information.  It should contain a single line stating
"username:password". The default value is taken from the ONE\_AUTH environment variable, or `$HOME/.one/one_auth` if
unset.

### template\_name

Name of the VM definition file (OpenNebula template) registered with OpenNebula.  Can be used with `template_uname` or
`template_uid` to further restrict which template to use if multiple users have the same template name. Only one of
`template_name` or `template_id` must be specified in the .kitchen.yml file. The default value is unset, or `nil`.

### template\_id

ID of the VM definition file (OpenNebula template) registered with OpenNebula.  Only one of `template_name` or
`template_id` must be specified in the .kitchen.yml file. The default value is unset, or `nil`.

### template\_uname

Username who owns the VM definition file (OpenNebula template).  Can be used with `template_name` to address naming
conflicts where multiple users have the same template name. The default value is unset, or `nil`.

### template\_uid

UID of the user who owns the VM definition file (OpenNebula template).  Can be used with `template_name` to address
naming conflicts where multiple users have the same template name. The default value is unset, or `nil`.

### vm\_hostname

Hostname to set for the newly created VM. The default value is the Test Kitchen instance name followed by a random
eight character suffix, for example `default-ubuntu-2404-h3k9qm1z`, so that several runs of the same suite can coexist
in one OpenNebula cloud.

### public\_key\_path

Path to SSH public key to pass to the VM, to use to authenticate with `username` when logging in or converging a node.
The default is the first of `~/.ssh/id_rsa.pub`, `~/.ssh/id_dsa.pub`, `~/.ssh/identity.pub`, `~/.ssh/id_ecdsa.pub` or
`~/.ssh/id_ed25519.pub` that is present on the filesystem. If none of them exist, set this explicitly -- the driver
fails with a message telling you to do so rather than trying to create the VM.

### username

This is the username used for SSH authentication to the new VM. The default value is `local`.

### memory

The amount of memory to provision for the new VM.  This parameter will override the memory settings provided in the
VM template. The default value is 512MB.

### vcpu

The number of virtual CPUs to provision for the new VM. This parameter will override the VCPU setting provided in the
VM template. The default value is 1.

### cpu

The amount of physical CPU allocated to the new VM, as understood by OpenNebula (a float, where 1 means one full core).
This parameter will override the CPU setting provided in the VM template. The default value is 1.

### user\_variables

A hash of variables to pass into the "user template" section of the VM, to customize the virtual machine. The default
value is `{}`.

### context\_variables

A hash of variables to pass into the "CONTEXT" section of the VM, to further customize the virtual machine. These
variables override any existing context variables that are provided as part of the specified VM template. The default
value is `{}`.

### require\_chef\_omnibus

Determines whether or not a Chef [Omnibus package][chef_omnibus_dl] will be
installed. There are several different behaviors available:

* `true` - the latest release will be installed. Subsequent converges will skip re-installing if chef is present.
* `latest` - the latest release will be installed. Subsequent converges will always re-install even if chef is present.
* `<VERSION_STRING>` (ex: `10.24.0`) - the desired version string will be passed the the install.sh script.
Subsequent converges will skip if the installed version and the desired version match.
* `false` or `nil` - no chef is installed.

The default value is unset, or `nil`.

### wait_for

This variable is used to override timeout for Fog's common `wait_for` method which states that it "takes a block and
waits for either the block to return true for the object or for a timeout (defaults to 10 minutes)".

### no\_ssh\_tcp\_check

To avoid test-kitchen's ssh tcp check in the create phase you can set `no_ssh_tcp_check` to `true` and do single sleep
instead. Sleep period is configured by `no_ssh_tcp_check_sleep`. The default for `no_ssh_tcp_check` is set to `false`.

### no\_ssh\_tcp\_check\_sleep

This variable configures a single sleep used when `no_ssh_tcp_check` is set to `true`. The default for `no_ssh_tcp_check`
is 2 minutes.

### no\_passwordless\_sudo\_check

To avoid test-kitchen's passwordless sudo check in the create phase you can set `no_passwordless_sudo_check` to `true`
and do single sleep instead. Sleep period is configured by `no_passwordless_sudo_sleep`. The default for
`no_passwordless_sudo_check` is set to `false`.

### no\_passwordless\_sudo\_sleep

This variable configures a single sleep used when `no_passwordless_sudo_check` is set to `true`. The default for
`no_passwordless_sudo_sleep` is 2 minutes.

### passwordless\_sudo\_timeout

This variable configures the max timeout will wait in the create phase for passwordless sudo to be setup. The variable
is used when `no_passwordless_sudo_check` is set to `false`. The default for `passwordless_sudo_timeout` is 5 minutes.

### passwordless\_sudo\_retry\_interval

This variable configures retry interval in the create phase to periodically check that passwordless sudo is setup. It
does this until max timeout (set by `passwordless_sudo_timeout`) is reached. The variable is used when
`no_passwordless_sudo_check` is set to `false`. The default for `passwordless_sudo_retry_interval` is 10 seconds.

### cloud\_init\_timeout

This variable configures the max timeout Test-Kitchen will wait in the create phase for cloud-init to complete. The
default for `cloud_init_timeout` is 10 minutes.

### cloud\_init\_retry\_interval

This variable configures retry interval in the create phase to periodically check that cloud-init fas finished
successfully. It does this until max timeout (set by `cloud_init_timeout`) is reached. The variable is used when
`no_cloud_init_check` is set to `false`. The default for `cloud_init_retry_interval` is 10 seconds.

### no\_cloud\_init\_check

To avoid test-kitchen to check for cloud-init completion in the create phase, you can set `no_cloud_init_check` to `true`
and cloud-init completion check will be ignored. If cloud-init is not used the check is skipped automatically. You could
use this to disable the cloud-init completion check when cloud-init is in use. The default for `no_cloud_init_check`
is set to `false`.

## Development

* Source hosted at [GitHub][repo]
* Report issues/questions/feature requests on [GitHub Issues][issues]

Pull requests are very welcome! Make sure your patches are well tested.
Ideally create a topic branch for every separate change you make. For example:

1. Fork the repo
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

### Running the tests

```shell
bundle install
bundle exec rake test      # RSpec unit tests
bundle exec rake rubocop   # Cookstyle/Chefstyle
bundle exec rake           # both
```

The unit tests are self-contained: they never contact an OpenNebula endpoint, never read the real `~/.ssh` or
`~/.one`, and never sleep. The suite enforces 100% line and branch coverage of `lib/`.

### Building the API documentation

API documentation is written as [YARD](https://yardoc.org/) comments. YARD lives in the `:development` bundle group and
is deliberately not part of the default task, so documentation is never a merge gate.

```shell
bundle config unset without
bundle install
bundle exec rake doc           # render HTML into doc/
bundle exec rake doc_coverage  # list anything still undocumented
```

## License

Apache 2.0 (see [LICENSE][license])


[issues]:           https://github.com/test-kitchen/kitchen-opennebula/issues
[license]:          https://github.com/test-kitchen/kitchen-opennebula/blob/master/LICENSE
[repo]:             https://github.com/test-kitchen/kitchen-opennebula
[chef_omnibus_dl]:  http://www.getchef.com/chef/install/
