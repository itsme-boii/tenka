# Halden — Self-Review

> **This is a self-review by the author, not an independent audit.** It was written 2026-10-03 against the code in this repo. Severity is the author's judgement.

## Scope

`src/ShareToken.sol`, `src/NavOracle.sol`, `src/SettlementDesk.sol`, `src/UpgradeTimelock.sol`, `script/Deploy.s.sol`.

## Method

- Read every function against the invariants I-1 to I-8 asserted in `test/invariant/SettlementDesk.invariant.t.sol`.
- 179 offline tests (unit, fuzz, invariant) and 5 fork tests against real USDC on Base.
- 100% line, statement, branch and function coverage of `src/`, with plain `forge coverage`.
- **18 mutation checks.** Each deliberately breaks one guard, and each is caught by the tests: nonce burn, receiver whitelist, buyer check, epoch guard, NAV change guard, upgrade delay, partial rounding, unpaid cap, partial gate, remaining check, nonce closing on a full fill, whitelist expiry boundary, burning from a frozen wallet, challenge window, veto access, correction timing, zero-guardian match, and upgrade-cancel access.
- A dry run of the deploy script.

## Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| T-1 | Medium (trust) | **A malicious upgrade could drain approved assets.** Sellers and buyers approve the desk proxy, and the owner can upgrade it. | **Reduced, not removed.** Upgrades are queued 48h ahead and the guardian can cancel them. The deploy script refuses a non-contract owner or a guardian equal to the owner on non-test chains. A compromised owner can still replace the guardian (T-9) and push an upgrade after 48 hours. Production needs a multisig owner. |
| T-2 | Low | **The valuation agent is a single trusted key.** A compromised agent can propose a wrong NAV within the 20% change cap, once per 6 days. | **Reduced.** A proposal waits out a challenge window (6 hours in the deploy script) and the guardian or owner can veto it. NAV never limits price, and orders can bind to an epoch, so the remaining impact is on buyers who rely on NAV and miss the window. |
| T-3 | Low | **Frozen shares could not be burned.** | **Fixed.** The owner can burn from a frozen or expired wallet. This is a power the README states, and there is still no way to move a holder's shares to someone else. |
| T-4 | Low | **ERC-1271 sellers are trusted to implement their own validation.** A wallet that returns the magic value for any signature can have its shares sold by anyone who knows the order. | Inherent to ERC-1271. The wallet's own risk. |
| T-5 | Info | **Public orders can be filled by any whitelisted buyer** when `buyer == 0`. A seller who wants one counterparty should name the buyer. | By design. |
| T-6 | Info | **Absurd prices revert.** A `payment / shares` ratio above `int256` max fails `SafeCast` when computing the event premium. | Cannot happen at real values. |
| T-7 | Info | **Changing the EIP-712 name or version in an upgrade invalidates all open orders.** | Plan a version bump with a cancel window. |
| T-8 | Info | **Coverage tooling gap.** `forge coverage` used to need `--ir-minimum` because `fill` hit stack-too-deep. | **Fixed.** `fill` is split into `_validate`, `_account` and the transfers, and one modifier became an internal check. Plain `forge coverage` now reports 100% of `src/`. |
| T-9 | Low | **The guardian is only as independent as its key.** The owner can call `setGuardian`, so an owner-key compromise can swap the guardian before queueing an upgrade. | Accepted for a demo. Hold the guardian separately from the owner multisig, or make guardian changes slow in a later version. |
| T-10 | Low | **A nonce stands for one order.** Reusing a nonce for a different order shares its fill progress. The desk never hands out more than either order allows (tested), but a seller can lose the ability to fill a second order. | Documented in the interface and README. |
| T-11 | Info | **A partial piece that would pay nothing is rejected.** With a tiny `payment` relative to `shares` (for example 1 base unit for 3 shares), later pieces can owe zero and revert, and the order cannot be completed. | Intended: no shares are given away for free. The seller can cancel. |
| T-12 | Info | **Fork tests use a public RPC when run by hand.** CI runs them only if a `BASE_RPC_URL` secret is set. | Optional. |

## Verified properties

- The desk holds no shares or stablecoin after any call (I-1).
- No fill or cancel changes share supply (I-2).
- Stablecoin and shares are conserved among actors (I-3).
- A closed order stays closed (I-4).
- Fills only happen between whitelisted parties, including when an expiry passes (I-5).
- NAV epochs grow by one and `asOf` never decreases (I-6).
- Across partial fills a seller is never paid below the signed price per share or above the signed total (I-7).
- A proposed NAV or correction never goes live before it is activated (I-8).
- A reentrant stablecoin cannot re-enter `fill`.
- Fee-on-transfer stablecoins are rejected.
- With real USDC, a fill works, and a seller or buyer blacklisted by Circle makes the fill revert with nothing moved.
- A signature is bound to every order field, the chain and the desk.
- The upgrade can only install the exact queued implementation, after 48h and inside the 7-day window, and only the owner can queue or run it.

## Not reviewed

A real Safe as an ERC-1271 seller (mocked only), a live testnet deployment, gas griefing across chains, and anything outside this repo.
