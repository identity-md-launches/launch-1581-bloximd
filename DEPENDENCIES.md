# Vendored dependencies

All dependencies are checked-in source files, not submodules. Only the paths
listed in `DEPENDENCIES.sha256` were copied; no package manager or download is
invoked by the build or tests. Upstream source contents are unmodified.

| Dependency | Release | Exact commit | Local contents | License |
| --- | --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0) | v5.4.0 | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` | `lib/openzeppelin-contracts/`: ERC20, IERC20, IERC20Metadata, Context, IERC6093 errors | [MIT](lib/openzeppelin-contracts/LICENSE) |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `lib/forge-std/src/`: upstream Solidity test helpers | [MIT](lib/forge-std/LICENSE-MIT) / [Apache-2.0](lib/forge-std/LICENSE-APACHE) |

Verify the vendored files locally with:

```sh
sha256sum --check DEPENDENCIES.sha256
```

Foundry and the version-pinned Solidity compiler are build tools supplied by the
execution environment. No compiler binaries are included in this repository.
