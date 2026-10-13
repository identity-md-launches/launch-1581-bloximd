// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BloxIMD (BLOX)
/// @notice An ERC-20 with 18 decimals and a fixed supply of one billion tokens.
/// @dev The entire supply is minted once to the immediate deployer. During an
/// IdentityMD launch this is the factory, which handles subsequent distribution.
contract BloxIMD is ERC20 {
    /// @notice The fixed supply in the token's smallest units (10^27).
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("BloxIMD", "BLOX") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
