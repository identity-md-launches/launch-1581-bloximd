// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @dev All transfers stay inside a closed set of holders, allowing the test to
/// account for every token after arbitrary sequences of approvals and transfers.
contract BloxIMDHandler is Test {
    BloxIMD public immutable token;
    address[4] public actors;

    constructor(BloxIMD token_) {
        token = token_;
        actors[0] = makeAddr("holder-0");
        actors[1] = makeAddr("holder-1");
        actors[2] = makeAddr("holder-2");
        actors[3] = makeAddr("holder-3");
    }

    function transfer(uint256 senderSeed, uint256 recipientSeed, uint256 amount) external {
        address sender = actors[senderSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(sender));
        vm.prank(sender);
        assertTrue(token.transfer(recipient, amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = infinite ? type(uint256).max : bound(amount, 0, token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        uint256 approved = token.allowance(owner, spender);
        uint256 available = token.balanceOf(owner);
        amount = bound(amount, 0, approved < available ? approved : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount));
        assertEq(token.allowance(owner, spender), approved == type(uint256).max ? approved : approved - amount);
    }

    function attemptOverdraw(uint256 senderSeed, uint256 recipientSeed) external {
        address sender = actors[senderSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        uint256 beforeSender = token.balanceOf(sender);
        uint256 beforeRecipient = token.balanceOf(recipient);
        vm.prank(sender);
        (bool success,) = address(token).call(abi.encodeCall(token.transfer, (recipient, beforeSender + 1)));
        assertFalse(success);
        assertEq(token.balanceOf(sender), beforeSender);
        assertEq(token.balanceOf(recipient), beforeRecipient);
    }
}

contract BloxIMDInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    BloxIMD private token;
    BloxIMDHandler private handler;

    function setUp() public {
        token = new BloxIMD();
        handler = new BloxIMDHandler(token);
        for (uint256 i; i < 4; ++i) {
            assertTrue(token.transfer(handler.actors(i), SUPPLY / 4));
        }

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BloxIMDHandler.transfer.selector;
        selectors[1] = BloxIMDHandler.approve.selector;
        selectors[2] = BloxIMDHandler.transferFrom.selector;
        selectors[3] = BloxIMDHandler.attemptOverdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyAlwaysEqualsOneBillionTokens() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_AllBalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
