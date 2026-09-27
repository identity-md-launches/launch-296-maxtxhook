# Contract interfaces

The JSON files in `docs/abi/` are complete compiler-generated ABI arrays. All token and cap amounts are integer base units with 18 decimals. Neither constructor is payable. Neither contract has a payable receive/fallback function or any administrative interface.

| Contract | Constructor | Artifact |
| --- | --- | --- |
| MAXT | `constructor()` | `src/MAXT.sol:MAXT` |
| MaxTxHook | `constructor(address manager)` | `src/MaxTxHook.sol:MaxTxHook` |

MAXT exposes standard ERC-20 `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, and `transferFrom`, with `Transfer` and `Approval` events and standard OpenZeppelin ERC-6093 errors. Transfers conserve the fixed supply. There is no permit extension. Infinite allowances are not decremented; finite allowances are. OpenZeppelin v5 does not emit `Approval` when consuming an allowance in `transferFrom`; read the view for current allowances.

| Hook view | Result |
| --- | --- |
| `CAP()` | `uint256`, 5000000000000000000000000 |
| `WINDOW_BLOCKS()` | `uint256`, 7200 |
| `poolManager()` | Configured immutable manager address |
| `endBlock(bytes32 poolId)` | Expiry block; zero for an uninitialized or non-ETH pool |
| `isCapActive(bytes32 poolId)` | `block.number < endBlock[poolId]` |
| `blocksRemaining(bytes32 poolId)` | `max(endBlock[poolId] - block.number, 0)` |
| `getHookPermissions()` | 14-field v4 tuple; only afterInitialize, beforeSwap, afterSwap true |

`poolId` is `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`, with the static ABI field types `address,address,uint24,int24,address`. Use the deployed pool's exact key, not the token address alone. Poll the views and block height; expiration occurs without a transaction and has no event.

The hook emits `CapWindowStarted(bytes32 indexed poolId, uint256 endBlock)` on native-ETH pool initialization. It has no per-swap hook event: use PoolManager `Initialize`, `ModifyLiquidity`, and `Swap` events for pool activity and Uniswap StateView for the current price. Reverted initialization/swap transactions retain no logs. Handle chain reorganizations when indexing.

Enabled callbacks are `afterInitialize(address,PoolKey,uint160,int24)`, `beforeSwap(address,PoolKey,SwapParams,bytes)`, and `afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)`. `PoolKey` is the tuple above; `SwapParams` is `(bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96)`; `BalanceDelta` is a packed `int256`. `amountSpecified < 0` denotes exact input; positive denotes exact output. `afterInitialize` returns its selector, `beforeSwap` returns `(selector,0,0)`, and `afterSwap` returns `(selector,0)`. Only the manager can invoke these functions.

Direct hook errors are `NotPoolManager()` and `CapExceeded(uint256 cap,uint256 requested)`. `requested` means the requested token output for a `beforeSwap` failure and the measured absolute token output for an `afterSwap` failure. Constructor validation may revert `HookAddressNotValid(address)`. During real pool swaps v4 wraps callback errors in `WrappedError(address target,bytes4 selector,bytes reason,bytes details)`, with `HookCallFailed()` in `details`. Decode `reason` using the hook ABI. Quoting/simulation clients need this nested decoding to display an accurate cap warning.

For frontend quotes, use v4 pool math or the appropriate quoter, including liquidity, fees and price impact; the spot price alone is insufficient. At the expiry boundary the pending transaction's mined block determines the cap, so a quote at an earlier block is only an estimate. The cap never replaces a user's minimum output or price limit.
