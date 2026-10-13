// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

contract BloxIMDTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;

    BloxIMD private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new BloxIMD();
    }

    function test_MetadataAndInitialSupply() public view {
        assertEq(token.name(), "BloxIMD");
        assertEq(token.symbol(), "BLOX");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorMintsOnceToCallerAndNotOrigin() public {
        vm.recordLogs();
        vm.prank(alice, bob);
        BloxIMD deployed = new BloxIMD();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(alice), SUPPLY);
        assertEq(deployed.balanceOf(bob), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_TransferEmitsEventAndDeliversExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 7 ether);
        assertTrue(token.transfer(alice, 7 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 7 ether);
        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_CanTransferWholeSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferOverBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_SelfTransferOverBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_TransferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApproveEmitsEventAndOnlyChangesCallersAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 10 ether);
        assertTrue(token.approve(spender, 10 ether));
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_ApproveReplacesAndRevokesAllowance() public {
        token.approve(spender, 10 ether);
        token.approve(spender, 3 ether);
        assertEq(token.allowance(address(this), spender), 3 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_ApproveDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_ApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_TransferFromSpendsFiniteAllowanceAndEmitsTransfer() public {
        token.approve(spender, 10 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4 ether));
        assertEq(token.allowance(address(this), spender), 6 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 4 ether);
        assertEq(token.balanceOf(alice), 4 ether);
        assertEq(token.balanceOf(spender), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 6 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 6 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteAllowanceIsUnchangedBySpendingAndCanBeRevoked() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_ZeroTransferFromWithoutAllowanceEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        token.approve(spender, 1 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 1 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromWithoutApprovalRevertsEvenForDeployer() public {
        token.transfer(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    function test_TransferFromCallerStillNeedsItsOwnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_AllowanceIsSpecificToSpender() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 1 ether);
    }

    function test_TransferFromInsufficientAllowanceRevertsWithoutChanges() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1 ether, 2 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 2 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_TransferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(alice);
        token.approve(spender, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, spender), 2 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromZeroRecipientRollsBackAllowance() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromZeroSenderCannotMint() public {
        vm.expectRevert();
        token.transferFrom(address(0), alice, 1);
        vm.expectRevert();
        token.transferFrom(address(0), alice, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_NoMintBurnOrAdministrativeEntrypoints() public {
        token.transfer(alice, 10 ether);
        bytes[] memory calls = new bytes[](24);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("setOwner(address)", bob);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[7] = abi.encodeWithSignature("initialize(address)", bob);
        calls[8] = abi.encodeWithSignature("unpause()");
        calls[9] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[10] = abi.encodeWithSignature("pause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[12] = abi.encodeWithSignature("blocklist(address)", alice);
        calls[13] = abi.encodeWithSignature("freeze(address)", alice);
        calls[14] = abi.encodeWithSignature("freezeAccount(address)", alice);
        calls[15] = abi.encodeWithSignature("setBlacklist(address,bool)", alice, true);
        calls[16] = abi.encodeWithSignature("setBlocked(address,bool)", alice, true);
        calls[17] = abi.encodeWithSignature("lock(address)", alice);
        calls[18] = abi.encodeWithSignature("disableTransfers()");
        calls[19] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[20] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[21] = abi.encodeWithSignature("seize(address)", alice);
        calls[22] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[23] = abi.encodeWithSignature("initialize()");

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(calls[i]);
            assertFalse(deployerSucceeded, "deployer reached a privileged entrypoint");
            vm.prank(bob);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            assertFalse(strangerSucceeded, "stranger reached a privileged entrypoint");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_RejectsEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(token).call{value: 1 ether}("");
        assertFalse(received);
        (bool unknown,) = address(token).call(hex"ffffffff");
        assertFalse(unknown);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RuntimeIsDeployableAndHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_TransfersPreserveSupplyAndDeliverExactAmount(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedTransferSpendsOnlyApprovedAmount(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), approved - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_OverdrawAlwaysReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_InsufficientApprovalAlwaysReverts(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
