# Sepolia measurement (2026-10-29)

- RESNFT v4 implementation (with ERC-4907 read interface): `0x481f3D03ce6BC417a8497f287492c9f0142CF09A` — upgraded via UUPS from `0xBd35De90Abf6a8135D6F7Fcac888834AcB244Ac5` (creation gas 35,616,602)
- ERC1967 proxy (initialize(364)): `0xC84d7c19349500DFFe5FaacB5c407232D44401ab` (creation gas 1,662,556)
- Blocks 12020286–12020377; 10 rounds; 71 transactions; gas price ≈ 0.05 gwei; RPC: ethereum-sepolia-rpc.publicnode.com
- Latency = wall-clock time from submission until `cast send` returned the receipt (one confirmation)
- Interrupted rounds (public-RPC stale reads, buyer out of funds) were discarded and re-run in full with `FROM=`; only complete rounds are in the CSV

| function | n | latency median (s) | min–max (s) | Sepolia gas (median) | local gas (Foundry, N=10) |
|---|---|---|---|---|---|
| addToEligibleList | 1 | 6.5 | 6.5–6.5 | 36,724 | 61,792 |
| addAsset | 10 | 11.0 | 4.7–12.0 | 524,008 | 182,940 |
| setForSale | 10 | 11.0 | 7.2–13.0 | 140,943 | 58,523 |
| buy | 10 | 12.0 | 10.1–12.9 | 242,270 | 134,009 |
| split(2) | 10 | 11.1 | 8.3–12.1 | 1,231,192 | 335,408 |
| merge(2) | 10 | 11.1 | 8.3–12.2 | 429,685 | 162,021 |
| setRent | 10 | 11.6 | 8.3–13.1 | 160,208 | 80,664 |
| changePrice | 10 | 11.0 | 10.1–13.2 | 135,713 | 36,305 |

All transactions: mean 11.02 s, median 11.11 s, max 13.18 s. Total fees 0.001434 SepoliaETH.

Note: Sepolia runs a repriced gas schedule (headers carry blockAccessListHash; code deposit ≈1,540 gas/byte; a plain ETH transfer to a new account costs 204,600 gas). Sepolia gas is therefore 2–4× the local Cancun/Prague figures and must not be read as mainnet cost. Latency (≈ one 12 s slot) is the transferable result.
addToEligibleList on Sepolia re-registered an already-registered buyer (no new storage slot), hence lower than local.
Deploying the 22.8 KB implementation needs an explicit gas limit (forge's local simulation underestimates under this schedule): `forge create contracts/RESNFT.sol:RESNFT --gas-limit 37000000 --gas-price 0.06gwei ...`.
