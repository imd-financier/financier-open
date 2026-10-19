# FINANCIER — mining and auction contracts

Reviewed source and tests for the FINANCIER Robinhood Chain (4663) mining-auction candidate.
This repository is a clean source snapshot, with no private development history or website.
No production token or mining deployment address is endorsed here.

## Current status

**Agent payout integration is blocked.** Official Intake purchase/completion is implemented,
but no authenticated complete agent/work/payout-wallet settlement interface has been
established. The immutable `FounderFundedMining` candidate cannot finalize agent rounds,
enable them later, upgrade or migrate its reserve. Unsupported agent allocations remain
quarantined. Resolve this limitation before deploying/funding a production reward system.
No completed independent IMD audit is claimed. Passing tests are not an audit or a guarantee.

## Contract entry point

`src/FounderFundedMining.sol` reuses the mining vault and auction implementation. It creates
`AttestedAgentRounds`, `PermanentV4Market` and `RobinhoodJobController` during construction.
All inherited contracts, helpers, interfaces and dependencies belong in an audit scope.
Other reserve receivers and mining variants are preserved for regression coverage; they are
historical alternatives, not additional components of the founder-funded deployment route.

Approved supply is 1B FINCR: 50% official initial liquidity, 10% official swarm, 40% mining.
After normal official launch and canonical source/allocation verification, the founder
transfers exactly 400M FINCR into the verified miner, then calls `arm()` explicitly.
The auction opens at 10 IMD and declines linearly to 0.5 IMD over one hour. The first successful
bid starts 365-day emissions. Every subsequent takeover resets the opening quote to 10 IMD.
Mining emissions are 80% financier and 20% equally shared qualifying distinct agents;
failed, empty, unrelated, duplicated or unauthenticated work earns no agent reward.
No quality score is required. Financier claims do not depend on work success.

Subsequent bid allocation: 80% outgoing financier, 5% work budget, 7.5% buyback/burn,
3.75% permanently locked supplemental LP and 3.75% Operations. The first bid has no outgoing
financier, so its otherwise outgoing 80% is added to work (85% total work). Optional payouts
and market execution are bounded and can defer without blocking a takeover. Deferred
credits/budgets remain accounted for. The market uses capped spot-based bounds, not an
independent price oracle; pre-transaction price manipulation/MEV remains a disclosed risk.
No trading toggle or custom launch gate is introduced.

## Reproduce

Foundry 1.7.1 and Solidity 0.8.30, optimizer 200, Cancun, metadata hash none.
Dependencies are git submodules pinned by `foundry.lock`.

```sh
git clone --recurse-submodules https://github.com/imd-financier/financier-open.git
cd financier-open
forge test
FOUNDRY_PROFILE=extended forge test --match-test invariant
```

Tests use explicitly synthetic identities, receipts, ownership and writer impersonation.
Saved official runtime bytecode is exercised locally; this does not turn synthetic test
contributions into authentic production work. The empty-work success regression demonstrates
why a nonzero completion hash cannot authorize a payout. Additional fixtures/older variants
exist to preserve accounting, authority, replay and custody regressions.

For a keyless local rehearsal against the genuine Robinhood contracts:

```sh
python script/rehearse-real-factory.py --out /tmp/financier-fork
```

This starts an account-free loopback Anvil fork. Privileged factory/writer impersonation and
synthetic FINCR exist only in that local fork. It never broadcasts or pays a live job. RPC
availability and runtime/fee drift can prevent a later reproduction; review failures explicitly.

`abi/` contains interfaces generated from the reviewed source. `SNAPSHOT.json` records
source/test/config hashes and reviewed code pins. No wallet key, signing tool, deployment
script, payable job or enabled production frontend is included.
