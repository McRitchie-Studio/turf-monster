# frozen_string_literal: true

require "test_helper"

# [unit] Solana::Config::MULTISIG_COSIGNER defaulted to 7ZDJ… on EVERY cluster.
# 7ZDJ… is Mr. McRitchie's Phantom and a MAINNET VaultState seat; the devnet
# vault does not seat it, so a deployed devnet app that forgot the variable
# would have asked for a cosignature the vault refuses. The default is now
# per cluster: mainnet keeps 7ZDJ… (turf-monster-mainnet relies on it), and a
# deployed app on any other cluster refuses to boot without the variable, with
# a message naming it. Development and test keep the literal for their fixtures.
class Solana::ConfigMultisigCosignerTest < ActiveSupport::TestCase
  MAINNET = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"
  QA_COSIGNER = "8UwJhRiNLr8uiqWyGUjgGDFqNEDY4SNQFfJud3ZSnowW"

  def resolve(value:, network:, deployed:)
    Solana::Config.resolve_multisig_cosigner(value: value, network: network, deployed: deployed)
  end

  test "a set variable wins on every cluster and every environment" do
    [["devnet", true], ["devnet", false], ["mainnet-beta", true]].each do |network, deployed|
      assert_equal QA_COSIGNER, resolve(value: QA_COSIGNER, network: network, deployed: deployed)
    end
    assert_equal QA_COSIGNER, resolve(value: " #{QA_COSIGNER}\n", network: "devnet", deployed: true)
  end

  test "deployed mainnet keeps the mainnet cosigner as its default" do
    assert_equal MAINNET, resolve(value: nil, network: "mainnet-beta", deployed: true)
  end

  test "a deployed devnet app without the variable refuses to boot and names it" do
    [nil, "", "  "].each do |value|
      error = assert_raises(RuntimeError) { resolve(value: value, network: "devnet", deployed: true) }
      assert_match(/\ASOLANA_MULTISIG_COSIGNER required on "devnet"/, error.message, value.inspect)
      assert_match(/8UwJ/, error.message, "the message names what QA sets")
      refute_includes error.message, MAINNET, "the message abbreviates the wallet it refuses"
    end
  end

  test "an unknown cluster on a deployed app is not mainnet and also refuses" do
    assert_raises(RuntimeError) { resolve(value: nil, network: "testnet", deployed: true) }
  end

  test "development and test keep the mainnet literal their fixtures use" do
    assert_equal MAINNET, resolve(value: nil, network: "devnet", deployed: false)
  end

  test "the mainnet default is seated on mainnet, per the signer fence" do
    seated = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml")).fetch("seated")
    assert_includes seated, Solana::Config::MAINNET_MULTISIG_COSIGNER
  end

  # The constant is resolved at LOAD time, so prove it is wired through the
  # resolver with this process's real facts rather than re-reading a literal.
  test "the loaded constant is the resolver's answer for this process" do
    assert_equal resolve(value: ENV["SOLANA_MULTISIG_COSIGNER"], network: Solana::Config::NETWORK,
                         deployed: Rails.env.production?),
                 Solana::Config::MULTISIG_COSIGNER
    source = Rails.root.join("app/services/solana/config.rb").read
    assert_match(/MULTISIG_COSIGNER = resolve_multisig_cosigner\(\s*value: ENV\["SOLANA_MULTISIG_COSIGNER"\], network: NETWORK, deployed: Rails\.env\.production\?/m,
                 source)
  end
end
