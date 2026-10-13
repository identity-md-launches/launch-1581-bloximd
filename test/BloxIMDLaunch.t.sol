// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @dev Test-only deployment/transfer actor. It models token movements, not the
/// production factory's authorization, distributor, pool initialization or swaps.
contract LaunchActor {
    function deploy(bytes32 salt) external returns (BloxIMD) {
        return new BloxIMD{salt: salt}();
    }

    function move(BloxIMD token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

contract BloxIMDLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;

    function test_Create2FactoryReceivesEntireSupply() public {
        LaunchActor factory = new LaunchActor();
        bytes32 salt = keccak256("blox-launch");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(BloxIMD).creationCode))
                    )
                )
            )
        );

        BloxIMD token = factory.deploy(salt);
        assertEq(address(token), predicted);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_LaunchDistributionClaimsAndPoolTransfersArriveWhole() public {
        LaunchActor factory = new LaunchActor();
        LaunchActor distributor = new LaunchActor();
        LaunchActor pool = new LaunchActor();
        address remainderRecipient = makeAddr("remainder-recipient");
        address claimant = makeAddr("claimant");
        address trader = makeAddr("trader");
        BloxIMD token = factory.deploy(keccak256("blox-distribution"));

        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 8 / 10;
        uint256 remainder = SUPPLY - swarmShare - poolShare;
        factory.move(token, address(distributor), swarmShare);
        factory.move(token, address(pool), poolShare);
        factory.move(token, remainderRecipient, remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(distributor)), swarmShare);
        assertEq(token.balanceOf(address(pool)), poolShare);
        assertEq(token.balanceOf(remainderRecipient), remainder);

        distributor.move(token, claimant, swarmShare);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(claimant), swarmShare);

        uint256 traded = 1_234 ether;
        pool.move(token, trader, traded);
        assertEq(token.balanceOf(trader), traded);
        assertEq(token.balanceOf(address(pool)), poolShare - traded);
        vm.prank(trader);
        assertTrue(token.transfer(address(pool), traded));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(address(pool)), poolShare);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
