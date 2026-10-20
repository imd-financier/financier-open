# Reproduce the candidate

Use Foundry v1.7.1, Solidity0.8.30+commit.73712a01, Cancun, optimizer200, viaIR disabled, metadata bytecode_hash=none. The exact compiler binary SHA256 is in BUILD_PINS.json. Dependencies are fully vendored; no dependency download or private checkout is needed. Their origin revisions are in foundry.lock and SOURCE_MANIFEST.json. Third-party license files accompany vendored code.

1. Verify each listed file's SHA256 and size against SOURCE_MANIFEST.json. The manifest excludes itself to avoid self-reference. The immutable Git commit authenticates the complete tree; use the separately reviewed archive digest as the release attestation.
2. Run `forge build`, then `python3 script/verify-build.py` to check every included reviewed ABI and all ten contract creation/runtime templates (nine protected core builds plus gatewayv2).
3. Run `forge test`; then `FOUNDRY_PROFILE=extended forge test --match-test invariant`. Offline tests include original security, solvency, conservation, replay, timing, custody, equal-agent, gateway authority and exploit regressions. Historical modules remain to reproduce their tests; they are not alternate approved production deployments.
4. Network-dependent actual-runtime rehearsal: `python3 script/rehearse-real-factory.py --match-test testTask33 --trace --out work/rehearsal`. The helper starts keyless loopback Anvil with zero accounts on a Robinhood4663 fork. It never broadcasts to Robinhood. Internet RPC/archive availability is required; use a fresh block because the public RPC can prune old state.

Fork tests check actual canonical runtime hashes while synthesizing launch parameters/provenance and accepted-agent evidence locally, impersonating privileged official service actors only inside Forge. Test balances/time are injected locally. These are runtime/integration tests, NOT an official launch, service source admission, real payment or authenticated FINANCIER accepted work. Gas logs are local execution measurements; production fee estimates must add transaction intrinsic/calldata costs and any chain-specific data charges and be freshly estimated per exact transaction.

Runtime templates contain immutable placeholders. Actual deployment checks must patch all immutable references with reviewed real values, compare runtime hash and exact creation input/constructor arguments, authenticate sender and canonical receipt and verify configuration/child provenance. Successful tests cannot make an unknown production address safe to fund.

No independent audit result or deployed application is asserted. Any reviewer should cite this exact public commit, affected files/lines, severity, concrete impact and reproducible proof, then give GO / FIX FIRST / NO-GO with trust assumptions separated from vulnerabilities.
