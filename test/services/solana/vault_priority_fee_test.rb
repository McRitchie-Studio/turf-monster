require "test_helper"

# Guards the mainnet priority-fee fix (2026-06-02): every Phantom-signed
# partial-signed TX (create_contest, enter_contest, set_contest_lock_time, …)
# must carry a ComputeBudget setComputeUnitPrice (0x03) + setComputeUnitLimit
# (0x02) instruction so a mainnet leader doesn't drop the (previously fee-less)
# TX under load. All those flows route through Vault#build_partial_signed, so
# we assert through the public create_contest builder.
class Solana::VaultPriorityFeeTest < ActiveSupport::TestCase
  COMPUTE_BUDGET_PROGRAM_B58 = "ComputeBudget111111111111111111111111111111".freeze

  # A client whose only job is to hand back a deterministic blockhash so the
  # builder doesn't touch the network.
  def vault_with_fake_blockhash
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) do |commitment: "finalized"|
      # A real 32-byte blockhash (base58 of 32 distinct bytes) so the message
      # layout matches production — an all-'1' string decodes to <32 bytes and
      # would desync the wire-format decoder below.
      Solana::Keypair.encode_base58((1..32).to_a.pack("C*"))
    end
    CosignFakeClient.teach(client)
    Solana::Vault.new(client: client)
  end

  # Decode a partial-signed base64 TX into its instruction list:
  # [sig_count][sigs...][header(3)][acct_count][acct_keys...][blockhash(32)]
  # [ix_count][ {program_idx, n_accts, acct_idxs.., data_len, data..} ... ]
  # Returns an array of { program_id_b58:, data: } in wire order.
  def decode_instructions(b64)
    bytes = Base64.decode64(b64).b
    off = 0
    sig_count, off = read_compact_u16(bytes, off)
    off += sig_count * 64
    off += 3 # message header
    acct_count, off = read_compact_u16(bytes, off)
    acct_keys = []
    acct_count.times do
      acct_keys << bytes[off, 32]
      off += 32
    end
    off += 32 # recent blockhash
    ix_count, off = read_compact_u16(bytes, off)
    ixs = []
    ix_count.times do
      program_idx = bytes[off].ord; off += 1
      n_accts, off = read_compact_u16(bytes, off)
      off += n_accts # 1 byte per account index
      data_len, off = read_compact_u16(bytes, off)
      data = bytes[off, data_len]; off += data_len
      ixs << {
        program_id_b58: Solana::Keypair.encode_base58(acct_keys[program_idx]),
        data: data
      }
    end
    ixs
  end

  # compact-u16 (shortvec) decoder — sufficient for our small counts.
  def read_compact_u16(bytes, off)
    val = 0
    shift = 0
    loop do
      byte = bytes[off].ord
      off += 1
      val |= (byte & 0x7f) << shift
      break if (byte & 0x80).zero?

      shift += 7
    end
    [val, off]
  end

  def build_create_ixs
    vault = vault_with_fake_blockhash
    creator = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" # distinct from the test admin key
    result = vault.build_create_contest(
      creator,
      "priority-fee-test-contest",
      entry_fee_by_currency: [19_000_000],
      max_entries: 29,
      payout_amounts: [300_000_000, 50_000_000],
      prize_pool: 1_000_000,
      season_id: 1,
      lock_timestamp: 0
    )
    decode_instructions(result[:serialized_tx])
  end

  test "create_contest TX carries a ComputeBudget setComputeUnitPrice ix" do
    ixs = build_create_ixs
    cb_ixs = ixs.select { |ix| ix[:program_id_b58] == COMPUTE_BUDGET_PROGRAM_B58 }
    assert_equal 2, cb_ixs.length, "expected price + limit ComputeBudget ixs"

    price_ix = cb_ixs.find { |ix| ix[:data].bytes.first == 0x03 }
    assert price_ix, "create_contest must carry a setComputeUnitPrice (0x03) ix"
    micro_lamports = price_ix[:data][1, 8].unpack1("Q<")
    assert_equal Solana::Vault::PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS, micro_lamports
    assert micro_lamports.positive?, "priority fee must be non-zero on mainnet"
  end

  test "create_contest TX carries a ComputeBudget setComputeUnitLimit ix" do
    ixs = build_create_ixs
    limit_ix = ixs.find do |ix|
      ix[:program_id_b58] == COMPUTE_BUDGET_PROGRAM_B58 && ix[:data].bytes.first == 0x02
    end
    assert limit_ix, "create_contest must carry a setComputeUnitLimit (0x02) ix"
    units = limit_ix[:data][1, 4].unpack1("V")
    assert_equal Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT, units
  end

  test "ComputeBudget ixs are ordered before the turf-vault program ix" do
    ixs = build_create_ixs
    program_b58 = Solana::Config::PROGRAM_ID
    cb_positions = ixs.each_index.select { |i| ixs[i][:program_id_b58] == COMPUTE_BUDGET_PROGRAM_B58 }
    prog_position = ixs.index { |ix| ix[:program_id_b58] == program_b58 }
    assert prog_position, "expected the create_contest program ix to be present"
    assert cb_positions.all? { |p| p < prog_position },
           "ComputeBudget ixs must precede the program ix (convention)"
  end
end
