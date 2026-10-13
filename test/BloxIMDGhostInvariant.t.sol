// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @notice Drives the token with several funded actors, an open set of fuzzed recipients, and ghost
/// accounting of everything that should have happened. Every successful call also checks its own
/// postconditions, and every failure-path action asserts the exact revert and that nothing moved.
/// @dev Unlike the closed-set handler in BloxIMDInvariant.t.sol, tokens here may leave the actor set
/// for arbitrary addresses (including the token contract itself), so conservation is checked over a
/// ghost-tracked holder set rather than a fixed array.
contract BloxIMDGhostHandler is Test {
    uint256 private constant MAX = type(uint256).max;

    BloxIMD public immutable token;
    address[] public actors;

    // Ghosts: who has ever held a balance, and the flows that explain each balance.
    address[] public holders;
    mapping(address => bool) public isHolder;
    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;

    // Ghost mirror of allowances granted between actors.
    mapping(address => mapping(address => uint256)) public mirrorAllowance;

    // Call accounting, so the suite can show its failure paths were actually exercised.
    uint256 public successfulTransfers;
    uint256 public rejectedCalls;

    constructor(BloxIMD token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    /// @dev Called by the test after it has funded the actors, so the ghosts start from reality.
    function recordInitialHolder(address account) external {
        _track(account);
        initialBalance[account] = token.balanceOf(account);
    }

    // ------------------------------------------------------------------
    // Successful operations with per-call postconditions
    // ------------------------------------------------------------------

    function transfer(uint256 senderSeed, uint256 recipientSeed, address rawRecipient, uint256 amount) external {
        address sender = _actor(senderSeed);
        address recipient = _recipient(recipientSeed, rawRecipient);
        amount = bound(amount, 0, token.balanceOf(sender));

        uint256 senderBefore = token.balanceOf(sender);
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(sender);
        assertTrue(token.transfer(recipient, amount), "transfer returned false");

        if (sender == recipient) {
            assertEq(token.balanceOf(sender), senderBefore, "self transfer changed the balance");
        } else {
            assertEq(token.balanceOf(sender), senderBefore - amount, "sender debited the wrong amount");
            assertEq(token.balanceOf(recipient), recipientBefore + amount, "recipient credited the wrong amount");
        }

        _track(recipient);
        sent[sender] += amount;
        received[recipient] += amount;
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = infinite ? MAX : bound(amount, 0, token.totalSupply());

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not set the allowance");

        mirrorAllowance[owner][spender] = amount;
    }

    function transferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 recipientSeed,
        address rawRecipient,
        uint256 amount
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _recipient(recipientSeed, rawRecipient);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);

        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount), "transferFrom returned false");

        if (owner != recipient) {
            assertEq(token.balanceOf(owner), held - amount, "owner debited the wrong amount");
            assertEq(token.balanceOf(recipient), recipientBefore + amount, "recipient credited the wrong amount");
        } else {
            assertEq(token.balanceOf(owner), held, "delegated self transfer changed the balance");
        }
        if (spender != owner && spender != recipient) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender's own balance moved");
        }
        uint256 expectedAllowance = allowed == MAX ? MAX : allowed - amount;
        assertEq(token.allowance(owner, spender), expectedAllowance, "allowance did not decrease by the spend");

        _track(recipient);
        sent[owner] += amount;
        received[recipient] += amount;
        mirrorAllowance[owner][spender] = expectedAllowance;
        successfulTransfers++;
    }

    // ------------------------------------------------------------------
    // Failure paths: each must revert with the exact error and move nothing
    // ------------------------------------------------------------------

    function overdraw(uint256 senderSeed, uint256 recipientSeed, address rawRecipient, uint256 amount) external {
        address sender = _actor(senderSeed);
        address recipient = _recipient(recipientSeed, rawRecipient);
        uint256 held = token.balanceOf(sender);
        amount = bound(amount, held + 1, MAX);

        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, held, amount);
        _expectRejected(sender, abi.encodeCall(token.transfer, (recipient, amount)), expected);
        assertEq(token.balanceOf(sender), held, "a failed overdraw changed the sender's balance");
    }

    function overspend(
        uint256 ownerSeed,
        uint256 spenderSeed,
        address rawSpender,
        uint256 recipientSeed,
        address rawRecipient,
        uint256 amount
    ) external {
        address owner = _actor(ownerSeed);
        // Sometimes an actor who may hold an allowance, sometimes a stranger who never could.
        address spender = spenderSeed % 3 == 0 ? _nonZero(rawSpender) : _actor(spenderSeed);
        address recipient = _recipient(recipientSeed, rawRecipient);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);

        bytes memory expected;
        if (allowed == MAX) {
            // Unlimited allowance: the only way to fail is to exceed the owner's balance.
            amount = bound(amount, held + 1, MAX);
            expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount);
        } else {
            amount = bound(amount, allowed + 1, MAX);
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        }
        _expectRejected(spender, abi.encodeCall(token.transferFrom, (owner, recipient, amount)), expected);
        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), held, "a failed transferFrom changed the owner's balance");
    }

    function transferToZero(uint256 senderSeed, uint256 amount) external {
        address sender = _actor(senderSeed);
        amount = bound(amount, 0, token.balanceOf(sender));
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        _expectRejected(sender, abi.encodeCall(token.transfer, (address(0), amount)), expected);
        assertEq(token.balanceOf(address(0)), 0, "the zero address received tokens");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0));
        _expectRejected(owner, abi.encodeCall(token.approve, (address(0), amount)), expected);
        assertEq(token.allowance(owner, address(0)), 0, "the zero spender gained an allowance");
    }

    function privilegedCall(uint256 callerSeed, address rawCaller, uint256 selectorSeed, uint256 targetSeed) external {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "seize(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "disableTransfers()"
        ];
        address caller = callerSeed % 2 == 0 ? _actor(callerSeed) : _nonZero(rawCaller);
        address target = _actor(targetSeed);
        uint256 supplyBefore = token.totalSupply();
        uint256 targetBefore = token.balanceOf(target);
        uint256 callerBefore = token.balanceOf(caller);

        bytes memory data = abi.encodeWithSignature(signatures[selectorSeed % signatures.length], target, MAX);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged entrypoint exists");
        rejectedCalls++;

        assertEq(token.totalSupply(), supplyBefore, "a privileged call changed the supply");
        assertEq(token.balanceOf(target), targetBefore, "a privileged call moved a holder's balance");
        assertEq(token.balanceOf(caller), callerBefore, "a privileged call credited its caller");
    }

    function sendEther(uint256 callerSeed, uint256 value) external {
        address caller = _actor(callerSeed);
        value = bound(value, 1, 1 ether);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        rejectedCalls++;
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // ------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _expectRejected(address caller, bytes memory data, bytes memory expectedRevert) private {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "a call that must fail succeeded");
        assertEq(ret, expectedRevert, "unexpected revert reason");
        assertEq(token.totalSupply(), supplyBefore, "a failed call changed the supply");
        rejectedCalls++;
    }

    function _track(address account) private {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev One recipient in four is an arbitrary fuzzed address outside the actor set, so tokens can
    /// leave the actors and the invariants have to account for them wherever they land.
    function _recipient(uint256 seed, address raw) private view returns (address) {
        if (seed % 4 == 0) return _nonZero(raw);
        return _actor(seed);
    }

    function _nonZero(address a) private pure returns (address) {
        return address(uint160(bound(uint256(uint160(a)), 1, type(uint160).max)));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract BloxIMDGhostInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 private constant ACTORS = 5;

    BloxIMD private token;
    BloxIMDGhostHandler private handler;

    function setUp() public {
        token = new BloxIMD();

        // The deployer keeps an uneven remainder and is itself an actor, as the factory would be.
        address[] memory actors = new address[](ACTORS + 1);
        actors[0] = address(this);
        for (uint256 i = 1; i <= ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("ghost-actor-", vm.toString(i)));
        }
        handler = new BloxIMDGhostHandler(token, actors);

        // Uneven funding so the actors start at different edges: one wei, a round share, nothing.
        uint256[ACTORS] memory shares = [uint256(1), SUPPLY / 10, SUPPLY / 3, 0, 123_456_789_012_345_678_901_234];
        for (uint256 i; i < ACTORS; ++i) {
            if (shares[i] > 0) assertTrue(token.transfer(actors[i + 1], shares[i]));
        }
        for (uint256 i; i < actors.length; ++i) {
            handler.recordInitialHolder(actors[i]);
        }

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = BloxIMDGhostHandler.transfer.selector;
        selectors[1] = BloxIMDGhostHandler.approve.selector;
        selectors[2] = BloxIMDGhostHandler.transferFrom.selector;
        selectors[3] = BloxIMDGhostHandler.overdraw.selector;
        selectors[4] = BloxIMDGhostHandler.overspend.selector;
        selectors[5] = BloxIMDGhostHandler.transferToZero.selector;
        selectors[6] = BloxIMDGhostHandler.approveZeroSpender.selector;
        selectors[7] = BloxIMDGhostHandler.privilegedCall.selector;
        selectors[8] = BloxIMDGhostHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The fixed supply never moves, whatever sequence of calls ran.
    function invariant_SupplyIsFixedAtOneBillion() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Conservation over an open set: every address that ever received tokens is tracked, and
    /// their balances add up to the supply with nothing created or lost along the way.
    function invariant_TrackedHoldersAccountForTheWholeSupply() public view {
        uint256 sum;
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY, "tracked balances do not sum to the supply");
    }

    /// @dev Each balance is exactly explained by what the account started with plus what it received
    /// minus what it sent. No hidden fee, rebase, or reflection touched it.
    function invariant_EveryBalanceEqualsItsGhostFlows() public view {
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            uint256 expected = handler.initialBalance(holder) + handler.received(holder) - handler.sent(holder);
            assertEq(token.balanceOf(holder), expected, "a balance disagrees with its recorded flows");
        }
    }

    /// @dev Allowances between actors always match the mirror: set by approve, reduced only by
    /// finite spends, never changed by failed calls or by transfers.
    function invariant_AllowancesMatchTheMirror() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < count; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.mirrorAllowance(owner, spender), "allowance drift");
            }
        }
    }

    /// @dev The zero address never holds anything and the contract never holds ether.
    function invariant_ZeroAddressAndEtherStayEmpty() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(address(token).balance, 0);
    }

    /// @dev No actor ever ends up holding more than the whole supply, and an actor funded with
    /// nothing can only hold what the ghosts say was sent to it.
    function invariant_NoActorExceedsSupplyOrItsInflows() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address actor = handler.actors(i);
            uint256 held = token.balanceOf(actor);
            assertLe(held, SUPPLY);
            assertLe(held, handler.initialBalance(actor) + handler.received(actor));
        }
    }
}
