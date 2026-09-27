# Maxtx (MAXT) and MaxTxHook

MAXT is an 18-decimal ERC-20 named **Maxtx**, with exactly **1,000,000,000 MAXT** minted once to its deployer. Its constructor takes no arguments. There is no external mint, burn, owner, administrator, pause, upgrade, transfer tax, or supply-changing entry point.

MaxTxHook limits individual buys on native-ETH/currency1 pools to **5,000,000 tokens** (5,000,000 × 10^18 base units) during the first **7,200 blocks** after each pool initializes. The intended currency1 is MAXT. The only constructor argument is `IPoolManager`; the production target is Sepolia (chain ID 11155111), manager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`. The token is learned from the pool key, with no token or owner constructor argument.

**The cap is per swap. Several swaps, even in one transaction, get around it. It slows single large buys and does not stop a determined buyer.** It also does not restrict token transfers, liquidity operations, or trading in other pools without this hook. The token itself has no trading restrictions.

## Behavior

| Situation | Result |
| --- | --- |
| Native-ETH pool initialization at block `B` | Stores `endBlock[poolId] = B + 7200`; emits `CapWindowStarted` |
| Buy, `block.number < endBlock`, exact output | `amountSpecified > CAP` reverts in `beforeSwap` with `CapExceeded(CAP, requested)` |
| Buy, active window, exact input | `abs(delta.amount1()) > CAP` reverts in `afterSwap` with `CapExceeded(CAP, received)` |
| Buy delivers exactly CAP | Allowed |
| Sell (`zeroForOne == false`) | Uncapped |
| `block.number >= endBlock` | No cap checks in either swap callback |
| Pool with non-native `currency0` | No window, initialization event, fee change, or hook delta |
| Direct callback from any address other than the configured PoolManager | Reverts `NotPoolManager()` |

The post-swap output check also applies to exact-output buys as a defensive bound. With ordinary v4 accounting, their output is already bounded by the request checked in `beforeSwap`. A request above CAP is refused even if its price limit would allow only a smaller partial fill. Large exact-input requests are allowed if their actual output is at most CAP.

`amount1` is the token leg of the pool's swap delta. For buys it is positive output; input fees are in the negative ETH leg, `amount0`. The hook widens to `int256` before taking the absolute value, including for `int128.min`. It never subtracts an LP fee from the output before comparing. Tests exercise both LP fees and an enabled PoolManager protocol fee.

The window is a block count, approximately one day only at 12 seconds per block. It starts at initialization, not the first buy. Anyone can initialize a valid v4 pool; there is intentionally no sender, price, fee, or token gate. All mutable state is keyed by the full `PoolId`, including currencies, fee, tick spacing and hook address. Non-ETH pools and uninitialized IDs report zero remaining blocks. Window addition is unchecked to avoid an initialization arithmetic revert; the assumption is a live-chain block height below `2^256 - 7200`.

## Permissions and settlement

Exactly `afterInitialize`, `beforeSwap`, and `afterSwap` are enabled: address flags **`0x10c0`**, mask **`0x3fff`**. All eleven other flags, including all return-delta flags, are false. The constructor calls `Hooks.validateHookPermissions`, so an address with incorrect bits cannot deploy. There is no initialization or liquidity gate; unused callbacks have no exposed entry points.

`beforeSwap` returns its selector, zero `BeforeSwapDelta`, and zero fee override. `afterSwap` returns its selector and zero delta. The hook has no outbound calls during callbacks, no accounting debt or claims, and no fund-handling functions. The pool's configured 3000 fee is the ordinary 0.3% LP fee; the hook adds no fee. `hookData` and the router's `sender` are ignored, so there is no user identity claim or router allowlist. `hookData` would be unauthenticated if a future integration chose to use it.

Routers/factories settle the real PoolManager's balances: ERC-20 debt uses **sync → transfer/transferFrom → settle**; native ETH debt uses `settle{value: amount}()`; credits use `take` or ERC-6909 claims. No hook settlement is needed. A failed cap check reverts the entire swap, including pool state and fees. Leaving any debt unsettled reverts the manager's unlock. Tests verify this rollback, missing-allowance failures, balance conservation, zero open deltas, no hook claims, and no hook/router residual funds.

## Build and tests

With Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py --check
```

The compiler is pinned in `foundry.toml`, with Cancun EVM, optimizer enabled (200 runs), and `bytecode_hash = "none"`. Cancun is required by the v4 PoolManager's transient storage. Dependencies are vendored as ordinary files in `lib/`; builds and tests need no package downloads, RPC, wallet, environment variables, FFI, or cheatcode filesystem access. Exact upstream commits and licenses are recorded in [docs/dependencies.json](docs/dependencies.json) and the vendored license files. A compiler binary is not bundled.

The suite deploys a real v4-core PoolManager at its actual local address, mines a CREATE2 hook address, runs factory initialization and seed settlement, and swaps through the upstream `PoolSwapTest` router. There is no `vm.etch`, mocked manager, or overridden permission validation. Fuzz tests cover buy sizes, sell sizes, initialization prices and fees, and token transfer conservation. Exact-input fuzz tests compare against the same real pool executed after the cap expires, restoring the entire snapshot before checking capped execution.

The protected input checks informed this implementation; their environment-dependent harness is not copied into the delivered suite. Equivalent local assertions include immutable supply, constructor permission validation, refusal of all enabled callbacks, and a runtime scan for proxy/destruction escape opcodes.

## Rehearsal parameters and deployment handoff

The supplied requirements did **not** include a completed manifest or its initial price, seed allocation, or liquidity ticks. The following explicit choices are the reproducible rehearsal proposal, defined in [test/helpers/LaunchParameters.sol](test/helpers/LaunchParameters.sol). The separate manifest contributor must use these values or reconcile changes and rerun the rehearsal before admission.

| Parameter | Value |
| --- | --- |
| Network / chain | Sepolia / 11155111 |
| Hook constructor | `MaxTxHook(IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543))` |
| Token constructor | `MAXT()` |
| Hook flags | 4288 (`0x10c0`) |
| Currency0 / currency1 | Native ETH (`address(0)`) / newly deployed MAXT |
| Pool fee / tick spacing | 3000 / 60 |
| `sqrtPriceX96` | `792281625142643375935439503360000` |
| Initial human price | 100,000,000 MAXT per ETH |
| Seed tick lower / upper | -887220 / 184200 |
| Seed token budget | 900,000,000 MAXT |
| Seed liquidity | `floor(seedTokens * 2^96 / (sqrtRatioAtUpper - sqrtRatioAtLower))` |
| Remaining allocation | 100,000,000 MAXT plus rounding remainder; destination selected by manifest/services |

Both assets have 18 decimals. The initial price is slightly above the upper initialized tick, so the seed is entirely MAXT and there is initially zero active liquidity and zero ETH. The first buy moves through the empty interval and enters the seed range. The factory-style rehearsal verifies that this succeeds. It proves the approved call shape using [test/helpers/LaunchFactory.sol](test/helpers/LaunchFactory.sol), a test-only model; no live factory source/address was supplied for byte-for-byte equivalence.

The deployment service must mine using the **actual CREATE2 deployer address**, salt, and `keccak256(creationCode || abi.encode(SepoliaPoolManager))`, requiring `uint160(predictedAddress) & 0x3fff == 0x10c0`. Any compiler, source, constructor or CREATE2 deployer change requires rechecking the salt. [test/helpers/HookMiner.sol](test/helpers/HookMiner.sol) contains the tested formula and bounded search. A local-test salt/address is not a Sepolia deployment artifact. The token creation code has no appended constructor arguments.

The intended sequence is factory deployment of the token (entire supply to factory), hook CREATE2 deployment, native-ETH pool initialization, and a one-sided seed during a PoolManager unlock with MAXT settlement. The service should keep initialization and seeding atomic to avoid an exposed initialization race. Source parameters and permissions are immutable; correcting them after launch requires a new deployment. The hook has no owner, setters, pause, sweep, upgrade, or protocol-fee control. It does not control LP position ownership or withdrawal policy; the factory/manifest/services must specify these separately.

## ABI, review, and operations

Compiler-generated ABIs are [docs/abi/MAXT.json](docs/abi/MAXT.json) and [docs/abi/MaxTxHook.json](docs/abi/MaxTxHook.json). Regenerate them with `python3 tools/export_abis.py`. [docs/ABI.md](docs/ABI.md) documents views, events, units and error decoding for the later frontend.

This contribution implements contracts, tests and ABI exports. The separate manifest assignment owns `launch.json`. Independent reviewers should use [docs/REVIEW_HANDOFF.md](docs/REVIEW_HANDOFF.md) to attack the accepted source and concrete manifest. These local checks are implementation evidence, not an independent audit or a fork rehearsal.

Services own source publication, signed artifact linkage, attestation, policy/admission, Sepolia code/address validation, final factory deployment and live rehearsal. Later frontend work reads the deployed hook and Uniswap StateView, verifies code at the published Sepolia PoolSwapTest router, and implements quotes, slippage protection and warnings for capped buys. No live transaction, funded wallet, source publication or website deployment is part of this contribution. The approved deployment address can also be cross-checked against [Uniswap's official deployment registry](https://developers.uniswap.org/docs/protocols/v4/deployments).
