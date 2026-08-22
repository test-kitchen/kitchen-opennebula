require "spec_helper"

RSpec.describe "Kitchen::Driver::OPENNEBULA_VERSION" do
  subject(:version) { Kitchen::Driver::OPENNEBULA_VERSION }

  it "is a frozen string" do
    expect(version).to be_a(String).and be_frozen
  end

  it "is a valid semantic version" do
    expect(version).to match(/\A\d+\.\d+\.\d+(\.\w+)?\z/)
  end

  it "is the version the gemspec publishes" do
    gemspec = Gem::Specification.load(
      File.expand_path("../../../kitchen-opennebula.gemspec", __dir__)
    )
    expect(gemspec.version.to_s).to eq(version)
  end
end
