# RES — Real Estate NFT Platform

Real-estate transactions on Ethereum: each property is an NFT, traded atomically through a UUPS-upgradeable smart contract with oracle-gated eligibility.

**Live demo:** https://res-real-estate.vercel.app (Sepolia testnet)
**Proxy:** `0x10B01918Fd967e77a7A39145804ef5138FBaDEb5`

## Structure

```
contracts/   RESNFT.sol — ERC-721 + UUPS proxy, atomic buy(), split/merge, on-chain rent
script/      Deploy.s.sol — Foundry deployment script
test/        RESNFT.t.sol (24 unit) · LiveChain.t.sol (3 live-chain) · e2e-ui.js (10 e2e)
frontend/    Static web UI (web3.js) — index.html, app.js, server.js, abi.json
```

## Quick start

```bash
# contract — build & test
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts OpenZeppelin/openzeppelin-contracts-upgradeable
forge build && forge test

# deploy to a local node
anvil
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# frontend
cd frontend && node server.js   # http://localhost:3000
```

The frontend talks directly to the chain via RPC — no backend. Switch network (local Anvil / Sepolia) from the header.

## Key features

- **Atomic purchase** — payment and NFT transfer in one transaction (ReentrancyGuard)
- **Oracle-gated eligibility** — only whitelisted wallets can trade (anti-fraud)
- **Split / merge** — divide a property NFT into up to 20 shares and merge them back
- **On-chain rent** — rental periods registered per property
- **Custom pricing** — per-buyer discounted price
- **Reissue** — oracle can void and re-mint a stolen NFT
- **UUPS upgradeable** — storage-safe upgrades

## Tests

37 tests total (24 unit + 3 live-chain + 10 end-to-end), all passing. Live-chain tests run against the deployed Sepolia proxy.

---
*A. Mohammadjani, M. Bastam, E. Ataie — "A Blockchain-Driven Paradigm for Improving Real Estate Transaction Efficiency and Reliability"*
