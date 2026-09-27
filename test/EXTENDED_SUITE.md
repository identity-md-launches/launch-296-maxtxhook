# Extended launch tests

Run `forge build` and `forge test`. All dependencies are already vendored; these tests need no RPC,
environment configuration, downloads, or fork. Build artifacts can be kept in disposable scratch with
`FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test --offline`.

The new suites reuse `HookFixture`: a real locally deployed v4 PoolManager, factory-deployed MAXT,
a CREATE2-mined hook with its original constructor validation, and the one-sided factory seed.
No implementation, manager bytecode, or callback is replaced.

## Single-unlock sequences

`MaxTxHookSequence.t.sol` adds a batch router that calls `manager.unlock` once, executes all swaps,
then settles their net balances. This differs from the existing repeated-swap test, which opens a
new unlock for each swap. Coverage includes:

- First buys at exactly CAP into the ETH-less factory seed; randomized batch lengths and amounts.
- Exact-input and exact-output buys at CAP within the same unlock, delivering more than CAP in total.
- A late exact-output CAP + 1 or exact-input output of CAP + 1 rejecting the entire batch.
- Restoration of price, tick, liquidity, fee growth, protocol fees, window and account balances
  after rejection, including after earlier swaps crossed the seed's upper tick.
- An oversized buy after a larger sell still rejecting, despite the smaller net token receipt.
- Uncapped sells in both modes within one unlock.
- Both buy modes rejecting above CAP at endBlock - 1 and succeeding at endBlock, after a fuzzed
  number of preceding buys has changed the price.

Failures must match the v4 wrapped error, callback selector, and exact `CapExceeded(CAP, amount)`
arguments. An unrelated router, funding, allowance, price-limit or settlement revert is a failure.

## Stateful campaign

`MaxTxHookInvariant.t.sol` targets only five handler actions: exact-input/output buys, exact-input/output
sells, and monotonic block advancement through expiry. It runs 128 sequences of 64 actions, with
unexpected handler reverts treated as failures. The deterministic handler test also exercises both
boundary blocks and all four swap modes.

Buy outputs range from one base unit through 2 x CAP. Exact-input buys use core price math to choose
a partial-fill limit with a known output, then assert the delivered amount and actual ETH debit.
Sell bounds use available liquidity so cap checks cannot be masked by exhausting the position.
The seed covers even 64 consecutive maximum-size buys. The campaign checks per-swap cap enforcement,
the immutable deadline, account balances against cumulative swap deltas, fixed supply, ETH/token
conservation, zero hook custody/claims, and complete settlement after every action. Setup exercises
both cap rejection paths; `afterInvariant` requires additional campaign activity.

The original suite retains coverage for unrestricted exact-input swaps, dust, non-ETH pools,
permissions, callback authorization, initialization and token behavior.

## Rehearsal scope

No `launch.json` was supplied in this working tree. The rehearsal uses the accepted values in
`helpers/LaunchParameters.sol`; it does not claim to validate a missing manifest's price or a live
factory deployment. No implementation defect was observed in these local checks.
