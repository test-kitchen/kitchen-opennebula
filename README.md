# kitchen-opennebula

[![Gem Version](https://badge.fury.io/rb/kitchen-opennebula.svg)](https://badge.fury.io/rb/kitchen-opennebula)
[![Test](https://github.com/test-kitchen/kitchen-opennebula/actions/workflows/lint.yml/badge.svg)](https://github.com/test-kitchen/kitchen-opennebula/actions/workflows/lint.yml)

A [Test Kitchen](https://kitchen.ci/) driver for [OpenNebula](https://opennebula.io/).

Test Kitchen builds a throwaway machine, applies your configuration to it, runs your tests against it, and tears it
down. This driver is the piece that does the building and tearing down: it instantiates a VM from an OpenNebula
template, waits until the VM is genuinely ready to be configured, and hands it off to your provisioner.

Everything else — how the machine is configured, how it's tested, how you connect to it — is handled by Test Kitchen's
other plugins and is the same as it would be on any other cloud.

> This documentation uses [Cinc Workstation](https://cinc.sh/) and the `cinc` commands throughout. Everything here
> works identically with Chef Workstation — see [Using with Chef](#using-with-chef).

## Before you start

You will need:

- **Ruby 3.1 or newer**, and Test Kitchen. If you use [Cinc Workstation](https://cinc.sh/start/workstation/), you
  already have both.
- **An OpenNebula cloud you can reach**, specifically its XML-RPC endpoint (typically port 2633).
- **OpenNebula credentials**, in the usual `username:password` form.
- **A registered OpenNebula template** to build VMs from, whose guest image meets the
  [requirements below](#preparing-a-guest-image).

## Installation

This driver ships as part of [Cinc Workstation](https://cinc.sh/start/workstation/). If you have Cinc Workstation
installed, there is nothing else to install. To install it into a standalone Ruby:

```shell
gem install kitchen-opennebula
```

Otherwise add it to your project's `Gemfile`:

```ruby
gem "kitchen-opennebula"
```

...and run `bundle install`.

## Quick start

### 1. Tell the driver where your cloud is

The driver reads the same two environment variables as the `one*` command line tools, so if those already work on your
machine, so does the driver:

```shell
export ONE_XMLRPC="http://opennebula.example.com:2633/RPC2"
export ONE_AUTH="$HOME/.one/one_auth"     # a file containing a single line: username:password
```

`ONE_AUTH` may hold either a path to a credentials file or the literal `username:password` string. If it is unset, the
driver falls back to `~/.one/one_auth`. Both settings can also be written into `kitchen.yml` — see
[Connecting to OpenNebula](#connecting-to-opennebula) — but keeping the password out of a file you commit is the better
habit.

### 2. Find the template you want to build from

```shell
onetemplate list
```

Note either the template's **name** or its **ID**. You will use exactly one of them.

### 3. Write a `kitchen.yml`

```yaml
---
driver:
  name: opennebula
  template_name: ubuntu-2404       # or: template_id: 42
  username: ubuntu                 # the login user baked into your image
  memory: 2048
  vcpu: 2

transport:
  name: ssh
  ssh_key: ~/.ssh/id_rsa           # the private half of the key the driver pushes

provisioner:
  name: cinc_infra

platforms:
  - name: ubuntu-24.04

suites:
  - name: default
    run_list:
      - recipe[my_cookbook::default]
```

The `platforms` entry names the instance and tells Test Kitchen whether to treat the guest as Unix or Windows (a name
starting with `win` means Windows) — but the actual operating system comes from the OpenNebula template, not from this
name. If you want to test several templates, give each platform its own `driver` block:

```yaml
platforms:
  - name: ubuntu-24.04
    driver:
      template_name: ubuntu-2404
  - name: rocky-9
    driver:
      template_name: rocky-9
```

### 4. Run it

```shell
cinc kitchen create        # build the VM and wait for it to be ready
cinc kitchen converge      # apply your configuration
cinc kitchen login         # ssh in and look around
cinc kitchen verify        # run your tests
cinc kitchen destroy       # delete the VM
```

`cinc kitchen test` does the whole cycle in one command.

For everything in `kitchen.yml` that is not driver-specific, see the
[Test Kitchen configuration reference](https://kitchen.ci/docs/reference/configuration/).

## Preparing a guest image

This driver hands OpenNebula's contextualization system your SSH public key and expects the guest to act on it. Your
image must:

- **Install the OpenNebula contextualization package** (`one-context`), so that the guest reads the `CONTEXT` section
  the driver populates.
- **Install the `SSH_PUBLIC_KEY` context variable** into the login user's `~/.ssh/authorized_keys`. The `one-context`
  package does this for you.
- **Give the login user passwordless sudo.** Test Kitchen's provisioners install and run software as root; the driver
  blocks until `sudo -n true` succeeds, so an image that prompts for a password will hang and then fail.

The driver also sets a `TEST_KITCHEN` context variable to `YES`, which your image can use to enable behaviour that
should only ever happen in a test VM.

If your image runs `cloud-init`, the driver detects that automatically and waits for it to finish before converging,
so your provisioner does not race against it.

### Making sure the SSH keys match

This is the single most common thing to get wrong. Two separate settings are involved:

- `driver.public_key_path` — the **public** key the driver pushes into the VM.
- `transport.ssh_key` — the **private** key Test Kitchen authenticates with.

They must be halves of the same pair. If you leave `public_key_path` unset, the driver pushes the first of
`~/.ssh/id_rsa.pub`, `~/.ssh/id_dsa.pub`, `~/.ssh/identity.pub`, `~/.ssh/id_ecdsa.pub` or `~/.ssh/id_ed25519.pub` that
exists — which may not be the key your SSH agent offers first.

## Configuration

All of these go under `driver:` in `kitchen.yml`.

### Connecting to OpenNebula

| Setting | Default | Description |
| --- | --- | --- |
| `opennebula_endpoint` | `$ONE_XMLRPC`, else `http://127.0.0.1:2633/RPC2` | URL of the OpenNebula XML-RPC daemon. |
| `oneauth_file` | `$ONE_AUTH`, else `~/.one/one_auth` | Path to a file holding a single `username:password` line. `$ONE_AUTH` may instead hold the credentials themselves. |

### Choosing a template

Set **exactly one** of `template_name` or `template_id`. Setting neither, or both, is an error.

| Setting | Default | Description |
| --- | --- | --- |
| `template_name` | none | Name of the OpenNebula template to build from. |
| `template_id` | none | ID of the OpenNebula template to build from. |
| `template_uname` | none | Owner's username, to disambiguate when several users have a template of the same name. Only used with `template_name`. |
| `template_uid` | none | Owner's UID, for the same purpose. **Must be quoted** — see [Troubleshooting](#troubleshooting). |

### Shaping the VM

| Setting | Default | Description |
| --- | --- | --- |
| `vm_hostname` | instance name plus a random suffix, e.g. `default-ubuntu-2404-h3k9qm1z` | Name given to the VM in OpenNebula. The random suffix lets several runs of the same suite coexist. |
| `username` | `local` | Login user for the VM. This is also what Test Kitchen's transport uses to connect, and it takes precedence over `transport.username`. |
| `public_key_path` | first existing of `~/.ssh/id_rsa.pub`, `~/.ssh/id_dsa.pub`, `~/.ssh/identity.pub`, `~/.ssh/id_ecdsa.pub`, `~/.ssh/id_ed25519.pub` | Public key pushed into the VM as `SSH_PUBLIC_KEY`. |
| `memory` | `512` | Memory in MB. Overrides the template. |
| `vcpu` | `1` | Number of virtual CPUs. Overrides the template. |
| `cpu` | `1` | Physical CPU share, where `1` is one full core. May be fractional. Overrides the template. |
| `context_variables` | `{}` | Extra variables merged into the template's `CONTEXT` section. These override anything the template sets, including the driver's own `SSH_PUBLIC_KEY` and `TEST_KITCHEN`. |
| `user_variables` | `{}` | Extra variables merged into the template's user template section. |

Networking and disks come from the OpenNebula template; the driver does not configure them.

### Waiting for the VM to be ready

After OpenNebula reports the VM as running, the driver runs three checks in order: the transport connectivity check,
the passwordless sudo check, and — only if cloud-init is detected — the cloud-init completion check. Each can be tuned
or skipped.

| Setting | Default | Description |
| --- | --- | --- |
| `wait_for` | `600` | Seconds to wait for OpenNebula to report the VM as running. |
| `no_ssh_tcp_check` | `false` | Skip the connectivity check and sleep instead. |
| `no_ssh_tcp_check_sleep` | `120` | Seconds to sleep when `no_ssh_tcp_check` is set. |
| `no_passwordless_sudo_check` | `false` | Skip the sudo check and sleep instead. |
| `no_passwordless_sudo_sleep` | `120` | Seconds to sleep when `no_passwordless_sudo_check` is set. |
| `passwordless_sudo_timeout` | `300` | Seconds to keep retrying the sudo check before giving up. |
| `passwordless_sudo_retry_interval` | `10` | Seconds between sudo retries. |
| `no_cloud_init_check` | `false` | Never wait for cloud-init, even if it is running. |
| `cloud_init_timeout` | `600` | Seconds to wait for cloud-init to finish. |
| `cloud_init_retry_interval` | `10` | Seconds between cloud-init polls. |

The `no_*` settings trade a real readiness check for a fixed sleep. They are an escape hatch for images the checks
cannot handle, not a speed-up — reach for them only after the real check has proven unworkable.

### Settings that are not the driver's

`require_chef_omnibus` is often seen in a `driver` block in older examples. It belongs to the provisioner, and
Test Kitchen quietly moves it there for you. Configure client installation on `provisioner:` instead.

## Troubleshooting

| Message | What it means |
| --- | --- |
| `template_name or template_id not specified in .kitchen.yml` | Neither was set. Set exactly one. |
| `Only one of template_name or template_id should be specified` | Both were set. Remove one. |
| `Could not find template to create VM. -- Verify your template filters and one_auth credentials` | Nothing matched. Check the name or ID with `onetemplate list`, and check that the account in your credentials can actually see that template. |
| `More than one template found. Please restrict using template_uname` | Several users own a template of that name. Add `template_uname`, or switch to `template_id`. |
| `Could not find one_auth file ...` | `ONE_AUTH` and `oneauth_file` both point at nothing. Create the file or export the credentials. |
| `OpenNebula credentials must be in 'username:password' form` | The credentials file or `ONE_AUTH` value is empty or missing the colon. |
| `Could not find an SSH public key. Set public_key_path in .kitchen.yml.` | No key was found in `~/.ssh`. Generate one, or set `public_key_path` explicitly. |
| `Passwordless sudo was not ready on <instance> after 300 seconds` | The login user cannot `sudo` without a password. Fix the image, or raise `passwordless_sudo_timeout` if it is simply slow to configure. |
| `Cloud-init failed on <instance>` | Cloud-init ran and reported failure. `kitchen login` and check `cloud-init analyze dump` — this is a problem in the image, not the driver. |
| `Cloud-init did not finish on <instance> after 600 seconds` | Cloud-init is still working. Raise `cloud_init_timeout`, or set `no_cloud_init_check: true` if you do not need to wait for it. |

### `template_uid` appears to be ignored

`template_uid` and `template_uname` are only applied as filters when they are **strings**. Written unquoted, a numeric
UID is parsed by YAML as an integer and silently ignored:

```yaml
template_uid: 0        # ignored
template_uid: "0"      # works
```

### The VM builds, but Test Kitchen cannot log in

Almost always a key mismatch — see [Making sure the SSH keys match](#making-sure-the-ssh-keys-match). Confirm the
driver pushed the key you expected by checking the VM's context in OpenNebula, then confirm `transport.ssh_key` is its
private half.

### Seeing what the driver decided

```shell
kitchen diagnose --all
```

This prints every setting the driver resolved, including the defaults and anything it read from the environment.

## Using with Chef

This driver is not tied to Cinc. The examples above use Cinc Workstation and the `cinc_infra` provisioner, but the
driver works exactly the same with [Chef Workstation](https://www.chef.io/downloads/tools/workstation) — run
`kitchen` instead of `cinc kitchen`, and use `chef_infra` instead of `cinc_infra`:

```yaml
provisioner:
  name: chef_infra

verifier:
  name: inspec
```

No driver configuration changes are needed.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/test-kitchen/kitchen-opennebula). See
[CONTRIBUTING.md](CONTRIBUTING.md) for development setup, how to run the tests, how to generate the API
documentation, and the release process.

## License

Apache 2.0 — see [LICENSE](LICENSE).
