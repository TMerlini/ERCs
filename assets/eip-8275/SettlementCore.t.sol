// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./SettlementCore.sol";

contract SettlementCoreTest is Test {
    SettlementCore public settlement;
    address public escrowReserve = makeAddr("escrowReserve");
    address public coordinator = makeAddr("coordinator");
    address public challenger = makeAddr("challenger");
    address public node1 = makeAddr("node1");
    address public node2 = makeAddr("node2");

    uint256 constant PERIOD_DURATION = 7 days;

    // Dummy rows for snapshot
    bytes dummyRows;

    function setUp() public {
        // Fund escrow reserve so it can receive ETH
        vm.deal(escrowReserve, 100 ether);
        
        settlement = new SettlementCore(PERIOD_DURATION, escrowReserve);
        
        // Build dummy contribution rows: two nodes, proportional contributions
        dummyRows = abi.encode(
            node1, uint256(70),  // 70 records served
            node2, uint256(30)   // 30 records served
        );

        // Fund accounts
        vm.deal(coordinator, 10 ether);
        vm.deal(challenger, 10 ether);
    }

    // ── 1. Commit succeeds with bond ───────────────────────

    function test_commitWithBond() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        (bytes32 snapRoot, uint256 committedAt, address coord, uint256 bond, , , , ) = settlement.periods(1);
        
        assertEq(snapRoot, root, "snapshot root");
        assertEq(coord, coordinator, "coordinator");
        assertEq(bond, 1 ether, "bond");
        assertTrue(committedAt > 0, "committedAt set");
    }

    // ── 2. Commit without bond reverts ─────────────────────

    function test_commitWithoutBondReverts() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        vm.expectRevert("bond required");
        settlement.commit(root);
    }

    // ── 3. Double commit reverts ───────────────────────────

    function test_doubleCommitReverts() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.prank(coordinator);
        vm.expectRevert("already committed");
        settlement.commit{value: 1 ether}(root);
    }

    // ── 4. Zero root reverts ───────────────────────────────

    function test_zeroRootReverts() public {
        vm.prank(coordinator);
        vm.expectRevert("zero root");
        settlement.commit{value: 1 ether}(bytes32(0));
    }

    // ── 5. Reveal with correct root succeeds ───────────────

    function test_revealCorrect() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        // Fast forward past freeze window
        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(coordinator);
        settlement.reveal(dummyRows);

        ( , , , , bytes memory revealedRows, uint256 revealedAt, , ) = settlement.periods(1);
        assertEq(keccak256(revealedRows), root, "revealed matches root");
        assertTrue(revealedAt > 0, "revealedAt set");
    }

    // ── 6. Reveal with wrong root reverts ──────────────────

    function test_revealWrongRootReverts() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        bytes memory wrongRows = abi.encode(node1, uint256(999));
        
        vm.prank(coordinator);
        vm.expectRevert("root mismatch");
        settlement.reveal(wrongRows);
    }

    // ── 7. Non-coordinator cannot reveal ───────────────────

    function test_nonCoordinatorCannotReveal() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(challenger);
        vm.expectRevert("not coordinator");
        settlement.reveal(dummyRows);
    }

    // ── 8. Challenge slashes bond to escrow ────────────────

    function test_challengeSlashesBond() public {
        bytes32 root = keccak256(dummyRows);
        uint256 escrowBefore = escrowReserve.balance;
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(coordinator);
        settlement.reveal(dummyRows);

        uint256 coordBalBefore = coordinator.balance;

        vm.prank(challenger);
        settlement.challenge{value: 1 ether}(1, "");

        // Escrow reserve should have received the slashed bond
        assertGt(escrowReserve.balance, escrowBefore, "escrow received slash");
        // Challenger gets their bond back
        assertGt(challenger.balance, 10 ether - 1 ether, "challenger refunded");
    }

    // ── 9. Challenge without bond reverts ──────────────────

    function test_challengeNeedsBond() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(coordinator);
        settlement.reveal(dummyRows);

        vm.prank(challenger);
        vm.expectRevert("bond required");
        settlement.challenge(1, "");
    }

    // ── 10. Bond-too-low challenge reverts ─────────────────

    function test_challengeBondTooLowReverts() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 2 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(coordinator);
        settlement.reveal(dummyRows);

        vm.prank(challenger);
        vm.expectRevert("bond too low");
        settlement.challenge{value: 1 ether}(1, "");
    }

    // ── 11. Axis separation: escrow ≠ reward pool ─────────

    function test_slashGoesToEscrowNotCoordinator() public {
        bytes32 root = keccak256(dummyRows);
        uint256 escrowBefore = escrowReserve.balance;

        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);
        vm.prank(coordinator);
        settlement.reveal(dummyRows);

        vm.prank(challenger);
        settlement.challenge{value: 1 ether}(1, "");

        // Slashed bond went to escrow, NOT coordinator
        assertEq(address(settlement).balance, 0, "contract holds nothing");
        assertGt(escrowReserve.balance, escrowBefore, "escrow received slash");
    }

    // ── 12. Events emitted correctly ───────────────────────

    function test_commitEmitsEvent() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        vm.expectEmit(true, true, true, true);
        emit SettlementCore.SnapshotCommitted(1, root, coordinator, 1 ether);
        settlement.commit{value: 1 ether}(root);
    }

    function test_revealEmitsEvent() public {
        bytes32 root = keccak256(dummyRows);
        
        vm.prank(coordinator);
        settlement.commit{value: 1 ether}(root);

        vm.warp(block.timestamp + PERIOD_DURATION - 30 minutes);

        vm.prank(coordinator);
        vm.expectEmit(true, true, true, false);
        emit SettlementCore.SnapshotRevealed(1, root);
        settlement.reveal(dummyRows);
    }
}
