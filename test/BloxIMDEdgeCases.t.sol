// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @dev Deploys the token's creation code with raw CREATE so the test can attach ether to the
/// constructor transaction, something Solidity refuses to compile against a non-payable constructor.
contract RawDeployer {
    function deployWithValue(bytes memory code, uint256 value) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }
}

/// @notice Edge inputs and failure paths that the main suite does not pin: one wei, the boundary of
/// the unlimited allowance, ether on the constructor, arbitrary fuzzed addresses, and round trips.
/// forge-config: default.fuzz.runs = 1000
contract BloxIMDEdgeCasesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 private constant MAX = type(uint256).max;

    BloxIMD private token;
    address private alice;
    address private bob;
    address private spender;
    address private otherSpender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        otherSpender = makeAddr("other-spender");
        token = new BloxIMD();
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_SupplyConstantIsOneBillionTimesTenToDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function test_MetadataIsReadableThroughTheStandardInterfaceByAnyCaller() public {
        IERC20Metadata meta = IERC20Metadata(address(token));
        vm.startPrank(alice);
        assertEq(meta.name(), "BloxIMD");
        assertEq(meta.symbol(), "BLOX");
        assertEq(meta.decimals(), 18);
        assertEq(meta.totalSupply(), SUPPLY);
        vm.stopPrank();
    }

    function test_ConstructorRefusesEther() public {
        RawDeployer deployer = new RawDeployer();
        vm.deal(address(deployer), 1 ether);
        bytes memory code = type(BloxIMD).creationCode;

        address withValue = deployer.deployWithValue(code, 1 wei);
        assertEq(withValue, address(0), "a non-payable constructor accepted ether");
        assertEq(address(deployer).balance, 1 ether, "ether left the deployer on a failed creation");

        address withoutValue = deployer.deployWithValue(code, 0);
        assertTrue(withoutValue != address(0), "deployment without value failed");
        assertEq(BloxIMD(withoutValue).balanceOf(address(deployer)), SUPPLY);
    }

    function test_EachDeploymentMintsItsOwnIndependentSupply() public {
        vm.prank(alice);
        BloxIMD second = new BloxIMD();
        vm.prank(bob);
        BloxIMD third = new BloxIMD();

        assertEq(second.totalSupply(), SUPPLY);
        assertEq(third.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(third.balanceOf(bob), SUPPLY);
        assertEq(second.balanceOf(bob), 0);
        assertEq(third.balanceOf(alice), 0);
        // The first token's ledger is untouched by the other deployments.
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_CreationCodeToleratesTrailingBytesAndStillMintsToCaller() public {
        // The factory appends the manifest's constructor arguments; this token declares none, so an
        // empty argument list must be the only thing that matters and extra calldata is ignored.
        RawDeployer deployer = new RawDeployer();
        bytes memory code = abi.encodePacked(type(BloxIMD).creationCode, abi.encode(uint256(0)));
        address deployed = deployer.deployWithValue(code, 0);
        assertTrue(deployed != address(0));
        assertEq(BloxIMD(deployed).totalSupply(), SUPPLY);
        assertEq(BloxIMD(deployed).balanceOf(address(deployer)), SUPPLY);
    }

    // ------------------------------------------------------------------
    // One wei and boundary balances
    // ------------------------------------------------------------------

    function test_OneWeiTransferDeliversExactlyOneWei() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_TransferAllButOneWeiThenTheLastWei() public {
        assertTrue(token.transfer(alice, SUPPLY - 1));
        assertEq(token.balanceOf(address(this)), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 1, 2));
        token.transfer(alice, 2);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_TransferToTokenContractSucceedsAndIsUnrecoverable() public {
        // Standard ERC-20 does not refuse its own address as a recipient. The README documents that
        // tokens sent here are lost; this pins that there is no path back out.
        assertTrue(token.transfer(address(token), 5 ether));
        assertEq(token.balanceOf(address(token)), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);

        // Nobody, including the deployer, holds an allowance from the token contract.
        assertEq(token.allowance(address(token), address(this)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 5 ether)
        );
        token.transferFrom(address(token), address(this), 5 ether);
        assertEq(token.balanceOf(address(token)), 5 ether);
    }

    // ------------------------------------------------------------------
    // Allowance boundaries
    // ------------------------------------------------------------------

    function test_AllowanceJustBelowMaxIsFiniteAndDecrements() public {
        token.approve(spender, MAX - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), MAX - 2, "max - 1 must behave as a finite allowance");
        assertEq(token.balanceOf(alice), 1);
    }

    function test_InfiniteAllowanceDoesNotCreateBalance() public {
        vm.prank(alice);
        token.approve(spender, MAX);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), MAX);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_AllowanceIsCheckedBeforeBalance() public {
        // Alice has nothing and approved nothing: the allowance error is the one reported, and no
        // state moves. Integrators relying on the error type should know which check runs first.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromEmitsOnlyTransferAndNoApproval() public {
        token.approve(spender, 10 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than one event");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), 4 ether);
        assertEq(token.allowance(address(this), spender), 6 ether);
    }

    function test_ApprovingTheSameValueTwiceIsIdempotentAndEmitsEachTime() public {
        token.approve(spender, 3 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 3 ether);
        assertTrue(token.approve(spender, 3 ether));
        assertEq(token.allowance(address(this), spender), 3 ether);
    }

    function test_SpendersHaveIndependentAllowancesFromTheSameOwner() public {
        token.approve(spender, 5 ether);
        token.approve(otherSpender, 2 ether);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 5 ether);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(address(this), otherSpender), 2 ether, "another spender's allowance moved");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, otherSpender, 2 ether, 3 ether)
        );
        vm.prank(otherSpender);
        token.transferFrom(address(this), bob, 3 ether);
        vm.prank(otherSpender);
        assertTrue(token.transferFrom(address(this), bob, 2 ether));
        assertEq(token.balanceOf(bob), 2 ether);
    }

    function test_SpenderCannotDelegateAnOwnersAllowanceOnward() public {
        token.approve(spender, 5 ether);
        // The spender approving a third party grants rights over the spender's own balance only.
        vm.prank(spender);
        token.approve(bob, 5 ether);
        assertEq(token.allowance(address(this), bob), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        // And the spender itself holds nothing to be spent.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, spender, 0, 1));
        vm.prank(bob);
        token.transferFrom(spender, bob, 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_OwnerCanApproveItselfAndSpendThroughTransferFrom() public {
        token.approve(address(this), 2 ether);
        assertTrue(token.transferFrom(address(this), alice, 2 ether));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_RevokedAllowanceCannotBeReplayed() public {
        token.approve(spender, 1 ether);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1 ether);
        // The same call again, with the allowance exhausted, must fail identically and move nothing.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // ------------------------------------------------------------------
    // Fuzzed properties over arbitrary addresses and amounts
    // ------------------------------------------------------------------

    function testFuzz_TransferToAnyNonZeroAddressDeliversExactly(address to, uint256 amount) public {
        to = _nonZero(to);
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);
        assertTrue(token.transfer(to, amount));
        if (to == address(this)) {
            assertEq(token.balanceOf(to), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_AccountWithNoBalanceCannotSendAnything(address from, uint256 amount) public {
        from = _nonZero(from);
        if (from == address(this)) from = alice;
        amount = bound(amount, 1, MAX);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, amount));
        vm.prank(from);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_PartialBalanceOverdrawRevertsWithExactValues(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_InfiniteAllowanceIsBoundedByOwnerBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, MAX);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), MAX);
        assertEq(token.balanceOf(alice), held);
    }

    function testFuzz_ApproveLastWriteWins(address who, uint256 first, uint256 second) public {
        who = _nonZero(who);
        token.approve(who, first);
        token.approve(who, second);
        assertEq(token.allowance(address(this), who), second);
        assertEq(token.balanceOf(who), who == address(this) ? SUPPLY : 0);
    }

    function testFuzz_FiniteAllowanceDecrementsByExactlySpent(uint256 approved, uint256 spent) public {
        approved = bound(approved, 0, MAX - 1);
        spent = bound(spent, 0, approved < SUPPLY ? approved : SUPPLY);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), approved - spent);
        assertEq(token.balanceOf(alice), spent);
    }

    function testFuzz_MultiHopChainConservesSupply(uint256 amount, uint8 hops) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 n = bound(hops, 1, 24);
        address previous = address(this);
        for (uint256 i; i < n; ++i) {
            address next = address(uint160(0x10000 + i));
            vm.prank(previous);
            assertTrue(token.transfer(next, amount));
            if (i > 0) assertEq(token.balanceOf(previous), 0, "an intermediate hop kept tokens");
            previous = next;
        }
        assertEq(token.balanceOf(previous), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SplitAndMergeRoundTripRestoresDeployer(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        token.transfer(alice, a);
        token.transfer(bob, b);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b);
        vm.prank(alice);
        token.transfer(address(this), a);
        vm.prank(bob);
        token.transfer(address(this), b);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedRoundTripRestoresBothBalanceAndAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        vm.prank(alice);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(alice, address(this), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testFuzz_UnknownSelectorsNeverChangeState(bytes4 selector, bytes32 word) public {
        // Any selector outside the ERC-20 surface must revert and leave the ledger as it was.
        bytes4[9] memory known = [
            IERC20.transfer.selector,
            IERC20.transferFrom.selector,
            IERC20.approve.selector,
            IERC20.allowance.selector,
            IERC20.balanceOf.selector,
            IERC20.totalSupply.selector,
            IERC20Metadata.name.selector,
            IERC20Metadata.symbol.selector,
            IERC20Metadata.decimals.selector
        ];
        bool clashes = true;
        while (clashes) {
            clashes = selector == token.INITIAL_SUPPLY.selector;
            for (uint256 i; i < known.length; ++i) {
                if (selector == known[i]) clashes = true;
            }
            if (clashes) selector = bytes4(uint32(selector) + 1);
        }
        token.transfer(alice, 1 ether);
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, word, word, word));
        assertFalse(ok, "an unknown selector was accepted");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    function _nonZero(address a) private pure returns (address) {
        return address(uint160(bound(uint256(uint160(a)), 1, type(uint160).max)));
    }
}
