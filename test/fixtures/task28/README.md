# Task28 official evidence fixture

`official-work-document.json` contains exact public bytes from
https://api.imd.fun/work-records/faf1900bc727aa5a37daefa1b47be8798f92c817ab858a0f25ee4abbccfa8986.json .
Its Ethereum Keccak is the URL hash. `official-receipt.json` preserves its actual public
Ethereum transaction/receipt and stored WorkRegistry response. The submission excerpt is
selected official API fields for the same job/agent/seat; it is not independently hash-committed.

This real historical Robinhood-funded job is **not** a prospectively eligible FINANCIER job.
Negative test mutations, runtime doubles, time/owner doubles and Solidity/fork acceptance
fixtures are synthetic, not new production receipts or an official cross-chain proof.

`artifact-reuse.json` is a **synthetic two-agent regression vector**, sharing the genuine
historical report hash above. The identities51000/51001 are test inputs, not authenticated
acceptances for that report. Python checks exact key encoding against the vector; Solidity
runs the real rounds preflight with rollback, finalization, raw events and both wallet claim
patterns using the same vector. No production eligibility is claimed.
