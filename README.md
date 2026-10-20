# FINANCIER ($FINCR)

FINANCIER is an IMD-denominated Dutch-auction mining protocol on Robinhood Chain (4663). A winning financier holds the exclusive iFinancier position and accrues FINCR for actual tenure, independently of agent work. Bids finance FINANCIER's own swarm-powered research, security and growth work. The separate agent stream rewards accepted FINANCIER work equally per distinct authenticated agent.

Website: https://imd-financier.pages.dev/ · X: https://x.com/imd_financier

**Prelaunch production candidate. No completed independent audit, deployed FINCR/miner, live mining or unattended automation is claimed.** The founder reports a successful Cloudflare deployment; a deployed website is not a deployed protocol. See DEPLOYMENTS.json and TRUST_AND_LIMITATIONS.md.

The auction opens at 10 IMD when armed and after every bid, declining to 0.5 IMD over one hour. Bids are spent; they are not refundable deposits. On later bids, 80% goes to the outgoing financier, 5% to work, 7.5% to buyback/burn, 3.75% to permanent supplemental liquidity and 3.75% to Operations. Genesis sends the otherwise outgoing 80% to work (85% total). Budgets do not prove execution or profit.

The intended official token launch supplies exactly 1B FINCR (18 decimals): 50% initial pool, 10% official IMD swarm, 40% founder remainder. The founder subsequently transfers exactly 400M to the independently verified miner and arms it. Over 365 days from the first accepted bid, 80% of mining emissions accrues to financiers; 20% goes to bounded equal-share accepted-agent rounds. Unsupported allocations, unused agent emissions and rounding dust remain quarantined.

`PublisherGateway` v2 → `RobinhoodJobController` → `FounderFundedMining` → `SeatOwnerAgentRounds` / `PermanentV4Market`. The gateway is initially paused. Its fixed founder can pause and replace the designated operator, which pauses forwarding. Its one-time controller binding must precede controller/miner binding. The controller publisher is the gateway contract, never the operator EOA.

The supervised publisher resolves official IMD Intake/job/records to committed Ethereum WorkRegistry documents, accepted agent IDs, submission seat token IDs and original NFT `ownerOf` snapshots. Ethereum evidence and joins are checked off-chain and relayed on Robinhood. **This is a trusted publisher, not a trustless bridge or proof of completeness.** A compromised publisher can misallocate the bounded 20% agent stream; financier claims remain independent. See ARCHITECTURE.md and TRUST_AND_LIMITATIONS.md.

Reproduce with Foundry v1.7.1 and Solidity 0.8.30: `forge build`, `forge test`, then `FOUNDRY_PROFILE=extended forge test --match-test invariant`. See VERIFICATION.md for canonical-runtime fork rehearsal and ABI/build checks. Dependencies are vendored at exact foundry.lock revisions. SOURCE_MANIFEST.json hashes every payload file except itself; BUILD_PINS.json records the reviewed creation/runtime templates and ABI evidence. Templates must be patched for actual immutable values before comparing deployed code.

All 23 project Solidity files are retained so reviewers can reproduce historical regressions. The production candidate is the founder-funded miner with gateway/controller/rounds/market above. Older receiver, forwarder, verifier, alternate miner and fee-router modules are historical or deferred, not additional production deployments. See CONTRACT_INVENTORY.md.

The original public launch source commit `153f1ebeca4951013168609adcc6b0a17c32dc54` remains unchanged and remains the token-launch request's source. This snapshot is a separate audit candidate. No private development Git history is exported. SPDX and dependency notices remain intact.
