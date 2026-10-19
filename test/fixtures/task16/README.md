# Observed Robinhood runtime fixtures

`imd-runtime.hex` and `intake-runtime.hex` are exact `eth_getCode` observations, not recreated contracts or generated work proofs. [Pinned block, addresses, Keccak/runtime and fixture-file SHA-256 hashes](../../../docs/evidence/task16/service.json) permit rechecking them. The fixtures matched again at that later service observation.

`Task16Base` etches those bytes into a clean local EVM and creates **synthetic storage**: test-only owner slots, enabled transfers, fixed price/payee and bidder balances. These are not observed real-chain permissions/storage and are never broadcast. Fault tests explicitly redirect/mimic calls only inside Forge. Production runtime checks are not relaxed for testing. The factory fork separately exercises actual deployed storage and actual vault payment.

No backend job is bought, no ownership attestation here is genuine, and no publication/license clearance follows from storing observed bytes. Existing source/fixture publication-rights blockers remain. Do not include these in an old release archive without updating/reviewing its allowlist and rights.
