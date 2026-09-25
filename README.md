# PvPad

Permissionless token launchpad: **bonding curve → graduate → locked Uniswap v4** pool behind a shared anti-snipe hook. Trade fee **1%** (`feeBps = 100`), split **50% King of the Pad / 50% creator** on the curve and after graduation. Launch fee (default **0.0005 ETH**) and king bids fund **Identity MD workers** via merkle epochs. **No house treasury.**

Product source of truth: [`SPEC.md`](./SPEC.md) (frozen).

## Module map

| Contract | Role |
|----------|------|
| `PvPadFactory` | `createLaunch`, genesis `#0`, `graduate`, pool registry |
| `PvPadToken` | Fixed `1e27` supply ERC-20 |
| `BondingCurve` | Per-launch constant-product buy/sell + fees |
| `PvPadHook` | Shared v4 swap skim (registry-gated launches only) |
| `KingOfThePad` | `claimKing(beneficiary)` → worker pot |
| `WorkerSubsidy` | Merkle epochs, `setEpoch` (updater), `claimWorker` |
| `FeeEscrow` | Pullable king/creator credits |

## Economics (defaults)

| Parameter | Value |
|-----------|--------|
| Trade fee | 1% (`feeBps = 100`) |
| Fee split | 50% king beneficiary / 50% launch creator |
| Launch fee | `0.0005 ETH` → 100% worker pot |
| Genesis `#0` | `$PVP` / Pepe Values Pepe, **zero** create fee |
| Graduation | `4.2 ETH` net curve reserve |
| King bid | `> claimPrice`, 100% → worker pot, +10% bump, start `0.01 ETH` |
| Updater (Sepolia demo) | `0x5b95A971B4583A5f011E9DA082acdD679b870D06` |

## Bonding curve math

Constant product with virtual reserves (pump.fun-class):

- `x = VIRTUAL_TOKEN + tokenReserve` (default virtual token `1_073_000_191e18`)
- `y = VIRTUAL_ETH + ethReserve` (default virtual ETH `30 ether`)
- `k = x * y`
- Buy: fee on **ETH input**; sell: fee on **ETH output**
- Full supply `1e9 * 1e18` minted to curve at launch

## Sepolia (chainId `11155111`)

| Item | Address |
|------|---------|
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Factory | _TBD after deploy_ |
| Hook | _TBD (mined `0x…C8` flags)_ |
| WorkerSubsidy / King / Escrow | _TBD_ |

Hook permissions: `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` only — **no `beforeInitialize`**.

## Keeper notes (off-chain)

1. `GET https://api.imd.fun/workers` → build Standard Merkle leaves `keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))))`.
2. Updater calls `setEpoch(root, windowStart, windowEnd)` (window ≤ 90 days).
3. Payees call `claimWorker` inside the window.
4. Solidity never calls IMD HTTP.

## Development

```bash
forge install
forge test
```

### Broadcast Sepolia

```bash
export PRIVATE_KEY=0x...
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url $SEPOLIA_RPC_URL --broadcast
```

Optional: `POOL_MANAGER` (defaults to Sepolia canonical address above).

## Threat model (short)

- **Updater** can drain worker pot via dishonest merkle root → multisig before mainnet.
- **Foreign pools** may attach the shared hook; only factory-registered pools split pad fees to the correct creator.
- Fee delivery uses try/catch paths; failed delivery must not revert user trades.

## License

MIT — see [LICENSE](./LICENSE).
