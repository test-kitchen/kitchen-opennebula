# Contributing to kitchen-opennebula

Thanks for your interest in improving kitchen-opennebula. Bug reports, feature requests, and pull requests are all welcome.

## Reporting issues

Source is hosted on [GitHub](https://github.com/test-kitchen/kitchen-opennebula); issues and questions go to
[GitHub Issues](https://github.com/test-kitchen/kitchen-opennebula/issues).

For bugs, please include:

- the version of kitchen-opennebula and Test Kitchen you are using
- your OpenNebula version
- your `kitchen.yml` with credentials and endpoints removed
- the output of the failing command, ideally with `-l debug`

The README's "Seeing what the driver decided" section explains how to get the
driver to show the template and settings it resolved, which is usually the
fastest way to characterise a problem.

## Development setup

```shell
git clone https://github.com/test-kitchen/kitchen-opennebula.git
cd kitchen-opennebula
bundle install
```

## Running the tests

```shell
bundle exec rake test      # RSpec unit tests
bundle exec rake rubocop   # Cookstyle / RuboCop
bundle exec rake           # both, the default task
```

To run a single spec file:

```shell
bundle exec rspec spec/kitchen/driver/opennebula_spec.rb
```

The unit tests are self-contained: they never contact an OpenNebula endpoint,
never read the real `~/.ssh` or `~/.one`, and never sleep. The suite enforces
**100% line and branch coverage** of `lib/`, so a change that adds code without
adding tests will fail on coverage alone.

## API documentation

API documentation is written as [YARD](https://yardoc.org/) comments. YARD lives
in the `:development` bundle group and is deliberately not part of the default
task, so documentation is never a merge gate.

```shell
bundle config unset without && bundle install
bundle exec rake doc           # render HTML into doc/
bundle exec rake doc_coverage  # list anything still undocumented
```

## Manual testing

Changes that touch VM instantiation or the readiness checks should also be
exercised against a real OpenNebula cloud, since the unit tests deliberately
never contact one.

You will need an XML-RPC endpoint, credentials, and a registered template whose
guest image meets the requirements in the README's "Preparing a guest image"
section. Confirm with `onevm list` that no VMs were left behind after
`kitchen destroy` — a run that fails partway through can leave one running.

## Submitting changes

1. Fork the repository.
2. Create a feature branch off `main`.
3. Make your change, adding or updating tests to cover it — the suite requires
   100% line and branch coverage.
4. Make sure `bundle exec rake` passes.
5. Push the branch to your fork and open a pull request.

Please keep pull requests focused on a single change — it makes review much
faster. Update the documentation in `README.md` when you add or change a
configuration option.

## Release process

Releases are handled by the maintainers.

1. Update `lib/kitchen/driver/opennebula_version.rb` with the new version.
2. Update `CHANGELOG.md`.
3. Merge to `main`; the publish workflow builds the gem and pushes it to
   RubyGems.
