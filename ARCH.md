# Halden — Institutional Overview

> **Status: working reference implementation. Unaudited. Not for real assets.** This page describes what exists today, and says plainly what does not.

## Summary

Halden is a settlement layer for the secondary market in fund shares that have a weekly NAV. An independent valuation agent publishes the NAV as a **reference price**. Holders then trade shares for stablecoin with other **whitelisted** holders at **any price**, above or below NAV. The shares and the payment move in **one transaction**, or neither moves.

It does not try to set the price, match buyers to sellers, or replace legal and compliance process. It makes a negotiated trade **safe to settle** and **easy to audit**.

## What is built

| Component | What it does |
|---|---|
| **ShareToken** | Fund share token. Only whitelisted wallets can send or receive. Whitelist entries can expire. |
| **NavOracle** | Weekly NAV from the valuation agent, with a change cap and a challenge window. A guardian can veto a NAV before it goes live. |
| **SettlementDesk** | Atomic delivery-versus-payment. Seller-signed orders, filled in full or in part, with optional NAV guards. |
| **Upgrade control** | Every contract is upgradeable, but an upgrade must be announced on-chain 48 hours ahead and can be cancelled by a guardian. |

Every fill records the NAV epoch, the NAV, its age, and the premium or discount in basis points, so each trade carries its own audit trail.

## How it is built

- **Solidity 0.8.28**, Foundry, OpenZeppelin 5.6.1 (pinned), UUPS proxies, EIP-712 signed orders, ERC-1271 support so a Safe can be the seller.
- **179 offline tests** (unit, fuzz, invariant), plus **5 fork tests** against real USDC on Base. The offline suite passes under a heavy profile with 10,000 fuzz runs.
- **100% line, statement, branch and function coverage** of the contracts.
- **18 mutation checks.** Each deliberately breaks one safeguard, and the tests catch every one.
- Conventions follow production DeFi practice: custom errors, two-step ownership, pause, reentrancy guard, namespaced storage. Notably, upgrades go through an in-contract 48-hour queue, the compiler is pinned, and deploy keys come from a keystore, never `.env`.

## Architecture

```
 valuation agent ──▶ NavOracle ──(6h challenge window, guardian veto)──▶ live NAV
                                                                           │ read-only reference
 seller ──signs order──▶ buyer ──fill──▶ SettlementDesk ──▶ ShareToken (whitelist enforced)
                                              │
                                              └──▶ Stablecoin (USDC)
```

| Role | Authority |
|---|---|
| Owner (multisig in production) | Mint and burn shares, pause, configure, queue upgrades |
| Compliance officer | Whitelist wallets, with or without expiry |
| Valuation agent | Propose NAVs and corrections |
| Guardian (separate key) | Veto a pending NAV, cancel a queued upgrade. Cannot queue or run upgrades. |

## Security

- **Atomic settlement.** Both legs are checked by balance change, so a fee-on-transfer or hostile token cannot short either side. A reentrant token cannot re-enter a fill. The desk never holds funds between transactions.
- **Bounded authority.** The desk can only move a seller's shares against that seller's valid, unexpired signature, for no more than the signed amount and price. A buyer's stablecoin moves only when the buyer submits the fill.
- **Compliance in the token.** The whitelist is enforced by the token itself, not only by the desk, so it holds on every transfer path. Removed or expired wallets are frozen.
- **Honest pricing record.** The NAV never limits price, but an order can bind to a NAV epoch or a maximum NAV age. A NAV correction creates a new epoch, so an open order is never silently re-priced.
- **Controlled upgrades.** 48-hour public queue, 7-day execution window, guardian veto. The deploy script refuses a non-contract owner or a guardian equal to the owner on non-test chains.
- **Real-token checks.** Tested against live USDC, including a blacklisted party: the fill reverts and nothing moves.

**Known limits.** The owner can replace the guardian, so the veto is only meaningful if the keys are held apart. The valuation agent is a single trusted key, softened by the challenge window and veto. A self-review is in `AUDIT.md`. **No independent audit has been done.**

## Not yet in place

Multisig owner, independent audit, KYC provider and jurisdiction rules, legal wrapper (transfer agent, registrar, reporting), order relay and UI, and a live testnet deployment.

## More

`README.md` (design and usage) · `AUDIT.md` (self-review)

— **Juboi**
