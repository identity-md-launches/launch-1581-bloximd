# BloxIMD (BLOX)

An immutable ERC-20 token for the IdentityMD custom token launch. The production
contract is [`src/BloxIMD.sol`](src/BloxIMD.sol), Solidity identifier **BloxIMD**.

| Parameter | Value |
| --- | --- |
| Name | `BloxIMD` |
| Symbol | `BLOX` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Constructor transaction value | `0` |
| Initial recipient | Immediate constructor caller (`msg.sender`) |
| Launch chain | Ethereum, chain ID `1` |

The constructor mints the entire supply exactly once. For a factory deployment,
the factory receives it; the wallet calling the factory does not. The token makes
no external calls during construction or transfers and needs no initialization,
external addresses, linked libraries, owner, or other configuration.

## Behavior and assumptions

The brief specifies no additional transfer rules, so BLOX uses the unmodified
OpenZeppelin Contracts v5.4.0 ERC-20 implementation. Transfers deliver the exact
amount and keep total supply constant. There are no taxes, rebases, mint or burn
entrypoints, administrative roles, pause/blacklist controls, upgrades, or proxies.
There are no reserved balances or allocations in the token constructor.

- `transfer`, `approve`, and `transferFrom` return `true` on success. Failures
  revert with OpenZeppelin's ERC-20 custom errors.
- Transfers to the zero address and approvals to a zero spender revert. Zero
  amount transfers between nonzero addresses succeed and emit `Transfer`.
- Self-transfers preserve balances but still require enough balance. Delegated
  self-transfers consume allowance normally.
- `approve` replaces the caller's allowance. A finite allowance decreases on
  `transferFrom`; `type(uint256).max` is unlimited and is not decreased. Holders
  can revoke either form with `approve(spender, 0)`.
- Successful approvals emit `Approval`. Transfers and the initial mint emit
  `Transfer`. OpenZeppelin v5 does not emit `Approval` when `transferFrom` spends
  allowance; integrations should read `allowance` for its current value.
- Direct ETH payments and unknown function selectors revert. There is no asset
  recovery function; tokens sent to this contract itself cannot be recovered.

These choices follow the [ERC-20 interface](https://eips.ethereum.org/EIPS/eip-20)
and the vendored [OpenZeppelin implementation](lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol).

## Build and test

Install Foundry and make Solidity **0.8.26** available in its compiler cache.
All Solidity dependencies are ordinary files under `lib/`; no dependency install,
submodule, network request, RPC endpoint, or environment variable is needed to
build or test once those tools are present.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun EVM output, optimizer settings (200
runs), and `bytecode_hash = "none"`. It enables neither FFI nor filesystem access.
The default fuzz tests run 512 cases each. Each stateful invariant runs 128
sequences of up to 64 actions, with unexpected handler reverts treated as failures.

Tests cover metadata and initial allocation, constructor caller versus origin,
the single mint event, exact transfers and events, zero/full/self transfers,
approval replacement/revocation, finite and unlimited approvals, unauthorized
spending, invalid addresses, insufficient balance/allowance and atomic rollback,
absent privileged entrypoints, runtime size and forbidden opcodes, CREATE2 factory
deployment, and conservation of supply across randomized action sequences.

The launch tests model exact token movements through factory, distributor,
pool and trader actors. They do not implement a real Uniswap pool or test swap
pricing. The supplied protected suite's real PoolManager integration runs in
IdentityMD's separate launch harness with its infrastructure and manifest data;
it is not included in this standalone project. Local test success is not an
independent security audit. See [SECURITY.md](SECURITY.md) for review scope.

## Deployment and operational responsibilities

Deploy the creation bytecode of `src/BloxIMD.sol:BloxIMD` with no encoded
constructor arguments and no ETH value. The artifact is
`out/BloxIMD.sol/BloxIMD.json`. Deploy it directly from the intended initial holder
or through IdentityMD's factory. An intermediate deployment helper would receive
the entire supply, so it must be able to forward tokens. The tests' `LaunchActor`
is only a test helper and must not be deployed as production infrastructure.

IdentityMD's launch process supplies its factory and manifest, checks the build,
and submits the deployment. This project contains no signing/broadcast script or
`launch.json`. No transactions have been submitted as part of this assignment.

The launch configuration provided in the brief is external to the token:

| Launch setting | Supplied value |
| --- | --- |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Pool fee | `12500` (1.25%) |
| Tick spacing | `60` |
| Initial price provenance | `79228162514264337593543950336` |
| `economics.poolBps` | `8000` |
| `economics.initialMarketCapWei` | `2500000000000000000000` |
| `economics.remainderTo` | `0xd6fac924dcda60610764cc645dbd3939fc18e1a3` |

The factory handles the 10% swarm distribution, 80% pool allocation and 10%
remainder. It derives the opening price from the supplied market cap, supply
and token address. The constructor does not perform any of these allocations.
The network's manifest and deployment steps remain responsible for those values,
the actual pool integration, independent review and source verification.

### After launch

No token settings need to be configured and there is no privileged token operator.
The launch operator should verify `name`, `symbol`, `decimals`, `totalSupply`,
the constructor's `Transfer` event, and the factory's distribution receipts
against the accepted artifact and manifest. Holders are responsible for their
keys and allowances. Applications should request only the allowance they need;
when replacing an existing allowance, revoke it first and confirm the revocation
before granting the replacement to reduce the standard approval race risk.

## Dependencies and license

The production dependency is a minimal, unmodified OpenZeppelin ERC-20 source
subset. Forge Standard Library is test-only. Exact revisions, license locations
and integrity verification are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).
Project code is MIT licensed; vendored code retains its upstream licenses.
