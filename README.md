# Halden

> **Demo. Unaudited. Not for real assets.** Halden is a small, carefully tested reference for one idea: a secondary market for fund shares where a weekly NAV is the *reference* price, but trades settle at *any* price, atomically, between whitelisted wallets.

For a short institutional summary, see [`ARCH.md`](ARCH.md).

## The idea

A fund publishes a NAV once a week, calculated by an independent valuation agent. Holders who need cash now will sell below it, and buyers want a discount. A hard price band around NAV would block exactly those trades, so Halden lets the price float. It makes the trade **safe** (atomic delivery-versus-payment between whitelisted parties) and **auditable** (every fill records the NAV it was done against, and the premium or discount).

```
valuation agent ── postNav (weekly) ──▶ NavOracle ── challenge window ──▶ live NAV
                                          guardian can veto here            reference price only

seller ── signs EIP-712 order ─────────┐
                                       ▼
buyer  ─── fill(order, sig, shares) ─▶ SettlementDesk
                                         checks: signature, nonce, deadline, whitelist, NAV guards
                                         stablecoin:  buyer  ──▶ seller
                                         shares:      seller ──▶ buyer        one transaction,
                                         emits NAV epoch, NAV, age, premium bps   both legs or neither
```

## Contracts

| Contract | Role |
|---|---|
| `ShareToken` | 18-decimal ERC20. Every transfer needs a whitelisted sender and receiver. A whitelist entry can expire. |
| `NavOracle` | Weekly NAV from the valuation agent. At most one post per 6 days, a cap on the change per post, and a 24h correction window. A new NAV waits out a challenge window before it goes live, and the guardian or owner can veto it. |
| `SettlementDesk` | Atomic fills of seller-signed orders, in full or in part. It never holds funds. |
| `UpgradeTimelock` | Shared base. Every contract is a UUPS proxy. An upgrade must be queued 48h ahead and run within 7 days, and the guardian can cancel it. |

## Pricing: float, with opt-in guards

There is no band. An order's `payment` is a total stablecoin amount, so the price is whatever the seller signs. A seller can protect an order from a moving NAV in two optional ways:

- `navEpoch`: the order only fills while that NAV epoch is current. A new NAV, or a correction, kills the order.
- `maxNavAge`: the order only fills while the NAV is at most that many seconds old.

If neither is set, the order fills at its price whatever the NAV does. A correction always creates a new epoch and never edits an old one, so an order can't be silently re-priced.

## Partial fills

An order with `allowPartial` can be filled in pieces. Each piece pays `payment * shares / orderShares`, rounded **up**, and the last piece pays the exact remainder. So the seller is never paid below the signed price per share, the total never exceeds the signed payment, and a piece that would cost nothing is rejected. A nonce stands for one order, so don't reuse a nonce for a different order.

## Roles and trust

| Role | Can | Cannot |
|---|---|---|
| `owner` | Mint and burn shares (burn works on a frozen wallet), pause the desk, rotate roles, tune the NAV change cap (max 50%) and challenge window (max 3 days), queue upgrades | Move a holder's shares to someone else, or fill orders for anyone |
| `complianceOfficer` | Whitelist wallets, with or without an expiry, and remove them | Mint, move funds, or post NAV |
| `valuationAgent` | Propose a NAV or a correction, withdraw its own proposal | Make a NAV live before its window ends |
| `guardian` | Veto a pending NAV, cancel a queued upgrade | Queue or execute an upgrade, post a NAV |
| seller / buyer | Sign and fill orders, cancel their own nonces | Move anyone else's assets |

**What you are trusting:** the valuation agent to post honest NAVs, the compliance officer to run the whitelist, and the owner not to push a malicious upgrade. The 48h upgrade delay and the guardian veto make an upgrade visible and stoppable, but the owner can replace the guardian, so the veto only means something if the guardian's key is held apart from the owner's. Sellers and buyers should approve only what they intend to trade.

## What the desk can and cannot do with your approvals

- A buyer's stablecoin moves only when the buyer is the caller. No one else can spend a buyer's allowance.
- A seller's shares move only against a valid, unused, unexpired signature from that seller, for no more than the signed amount and price.
- The desk holds nothing between transactions. Tests assert its balances are always zero.
- A wallet that is removed from the whitelist, or whose entry expires, is **frozen**. It can't send or receive until re-added.

## Run it

```bash
forge build
forge test                            # 179 offline tests: unit, fuzz, invariant
FOUNDRY_PROFILE=ci forge test         # 10,000 fuzz runs, deep invariants
forge coverage --report summary       # 100% of src/
forge fmt --check

# 5 more tests against real USDC on Base; they skip when no RPC is set
BASE_RPC_URL=<a Base RPC> forge test --match-path "test/fork/*"
```

Deploy (testnet, key from a keystore, never from `.env`):

```bash
cp .env.example .env                  # fill in addresses
cast wallet import halden-deployer --interactive
forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_SEPOLIA_RPC_URL \
    --account halden-deployer --broadcast --verify
```

Addresses are written to `deployments/<chainId>.json`. On any chain other than a testnet the script refuses to run unless `OWNER` is a contract (a multisig) and `GUARDIAN` is a different, non-zero address.

## Not in scope

No order book or relay, no KYC provider or jurisdiction rules, no second signer on the valuation agent beyond the challenge window and veto, and no legal wrapper (transfer agent, registrar, reporting). A real deployment needs a multisig owner, an independent audit, and all of the above. See `AUDIT.md` for the self-review.
