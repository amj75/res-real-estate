# RES — Real Estate NFT Platform (v4)

Borderless real-estate transactions on Ethereum. Each property, and each fractional share of a property, is an ERC-721 token. Every country's land registry runs its own **oracle** (a multisig wallet), and the oracles together form a DAO, the **OracleCouncil**, that governs the contract.

This repository accompanies the manuscript *"Reengineering Real Estate Transactions Through Blockchain-Based Tokenization and Smart Contracts"* (A. Mohammadjani, M. Bastam, E. Ataie — University of Mazandaran). Tag `v4.0.1` is the exact code and data reported in the revised manuscript. It adds the per-function cost benchmark to `v4.0.0` and restricts the market-wide pause to the council.

## Design in brief

- **Federated oracles.** Countries are identified by their ISO 3166 numeric code (e.g. 364 = Iran, 276 = Germany).
  - Each country's oracle is its land registry's multisig. It verifies identities, mints property tokens, executes court orders and records leases, and does so only within its own jurisdiction.
  - A buyer verified by one country can buy property in any other country.
- **DAO governance (`OracleCouncil`).** The council owns the contract. Every decision needs two thirds of the active member countries and takes effect immediately.
  - Decisions: suspending a compromised oracle, admitting a country, replacing an oracle address, pausing and unpausing the whole market, and upgrading.
  - The country being decided on does not vote.
  - No oracle has market-wide power. A country can stop only its own market and the wallets it verified (`suspendSelf` or a council suspension).
  - A new or replacement oracle address must first request membership itself (`requestOracle`). Members verify it off-chain before approving.
- **Compromise detection.**
  - Every oracle action carries a mandatory registry case reference, `caseRef = keccak256(country, caseNo, salt)`, and emits `OracleAction`. An on-chain action with no matching registry case indicates a compromised key.
  - Each country has a guardian key that can only suspend its own oracle (`suspendSelf`).
- **Identity binding.** `registerWallet` requires a signature from the wallet itself (EIP-191 / ERC-1271, replay-protected by nonce and chain id) and stores only a hashed identity commitment. No personal data is stored on-chain.
- **Freezes by legal order.**
  - Global: by the wallet's registering country (`removeFromEligibleList`).
  - Local: each country for its own jurisdiction (`freezeLocal`).
- **Atomic purchase.** `buy()` checks eligibility and the exact price, transfers the token and pays the seller in one transaction.
  - There is no escrow, and an underpayment or overpayment reverts.
  - The exact-price rule also defeats seller front-running.
- **Split / merge.** A whole property can be split into 2–20 percentage shares and merged back by whoever holds all the shares. Ownership always sums to exactly 100%.
- **Right of use.** Stored on the property token itself, following the ERC-4907 pattern (`userOf`, `userExpires`, `UpdateUser`). It is set only by the jurisdiction's oracle (`setRent`, `changeRenter`).
- **Single transfer gate.** Every token movement passes through `_update`, which enforces eligibility, freezes, suspension and pause, and clears listings, discounts and leases.
- **UUPS upgradeable.** Storage layout is append-only. The v3 → v4 upgrade path (`initializeV2`) is tested.

## Repository layout

```
contracts/   RESNFT.sol (ERC-721 + UUPS) · OracleCouncil.sol (DAO, owner of RESNFT)
test/        RESNFT · Adversarial · Federation · Invariant · InvariantFederation · Scalability · Cost · CouncilScale · LiveChain (Foundry)
             helpers/MultisigOracle.sol (minimal k-of-n multisig standing in for Safe)
             legacy/RESNFTv3.sol (previous version, for upgrade and gas comparison)
             e2e-ui.js (UI end-to-end test with a mocked wallet)
script/      Deploy.s.sol (Deploy · Upgrade · Federation) · sepolia_bench.sh (testnet latency) · sepolia_finality.sh (time to finality)
app/         Web UI (web3.js v4, MetaMask) · index.html · app.js · server.js · ABIs
results/     Raw evaluation data reported in the paper
```

## Build and test

Requires [Foundry](https://getfoundry.sh) (tested with forge 1.5.1) and Node.js (for the UI test).

```bash
git clone https://github.com/amj75/res-real-estate.git && cd res-real-estate
git submodule update --init      # dependencies pinned to exact commits (no --recursive needed)
forge build
forge test                       # 85 tests; the 3 LiveChain tests are skipped without a local node
node test/e2e-ui.js              # UI end-to-end test (10 checks)
```

Dependencies are git submodules pinned to the exact commits used for the paper:

- forge-std `48014d1`
- OpenZeppelin Contracts `eca4003` (5.7.0 development line)
- OpenZeppelin Contracts Upgradeable `f8fc282`

With these, the gas benchmarks below reproduce `results/scalability.csv`, `results/cost.csv` and `results/council_scale.csv` exactly. The bytecode of the Sepolia implementation matches a local build except for the embedded self-address immutable.

Gas benchmark (each call measured as a separate transaction with cold storage):

```bash
forge test --match-contract Scalability -vv --isolate | grep -o "BENCH,.*"                 # results/scalability.csv
NO_DIFF=true forge test --match-contract Cost -vv --isolate | grep -o "COST,.*"   # gas column of results/cost.csv
forge test --match-contract Cost -vv --isolate | grep -o "COST,.*"                # new/freed slot columns of results/cost.csv
forge test --match-contract CouncilScale -vv --isolate | grep -o "COUNCIL,.*"     # results/council_scale.csv
```

The cost benchmark runs twice because recording state diffs warms storage slots: gas comes from the `NO_DIFF=true` run, slot counts from the other.

## Run locally

```bash
anvil
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://localhost:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil test key #0
cd app && node server.js         # http://localhost:3000
```

The UI talks to the chain directly; there is no backend. To use another network or contract, pass URL parameters: `?rpc=<url>&chain=<id>&contract=<proxy>&deployBlock=<n>`.

## Sepolia deployment (evaluation)

| | Address |
|---|---|
| Proxy (RESNFT) | `0xC84d7c19349500DFFe5FaacB5c407232D44401ab` |
| Implementation (current) | `0x08e52BD05F1dafc0B94aff5463eac706F30853f4` |
| Implementation (latency measurement) | `0x481f3D03ce6BC417a8497f287492c9f0142CF09A` |

The two implementations differ only in `pause()`, which the current one restricts to the owner (the council); local gas of every measured function is identical.

Sepolia currently charges about 1,540 gas per byte of deployed code. The forge script's local simulation underestimates this, so deploy the implementation with an explicit limit, for example `forge create contracts/RESNFT.sol:RESNFT --gas-limit 37000000`. Then deploy an `ERC1967Proxy` with `initialize(uint16 country)`.

Testnet latency benchmark (writes `results/sepolia_latency.csv`; `FROM=<round>` resumes):

```bash
RPC_URL=... PROXY=... ORACLE_PK=... BUYER_PK=... ROUNDS=10 bash script/sepolia_bench.sh
```

Federation setup: each country's Safe first sends `requestOracle(country, guardian)`. Then run:

```bash
PROXY=... COUNTRIES=364,276 COUNTRY_ORACLES=<safe364>,<safe276> forge script script/Deploy.s.sol:Federation ...
```

This approves the founding members and transfers ownership to a new `OracleCouncil`.

## Results (`results/`)

| File | Content |
|---|---|
| `scalability.csv` | Full transaction gas per function for N = 10 … 3000 properties/wallets, v3 vs v4 |
| `cost.csv` | Gas, new and freed storage slots for 27 functions (steady state) |
| `council_scale.csv` | Gas of a council decision (proposal, each vote, total) with 3 … 100 member countries |
| `deployment_gas.csv` | Deployment gas of each contract (local Prague and Sepolia) |
| `sepolia_latency.csv`, `sepolia_summary.md` | Sepolia measurement: 10 rounds, 71 transactions, confirmation latency and gas |
| `sepolia_finality.csv` | Sepolia: time to inclusion and to finality for 10 transactions (`script/sepolia_finality.sh`) |
| `slither_v4.txt`, `slither_council.txt`, `slither_v3.txt`, `slither_version.txt` | Slither static analysis output |

## Earlier version

The previous public version (v3, single oracle) is commit `5614ce4`. Its Sepolia deployment is at `0x10B01918Fd967e77a7A39145804ef5138FBaDEb5`. The demo at https://res-real-estate.vercel.app now runs v4 against the proxy `0xC84d7c19349500DFFe5FaacB5c407232D44401ab`.
