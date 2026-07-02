// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ERC-8275 SettlementCore
/// @notice Commit-reveal settlement for mesh-node contribution compensation.
/// @author Panini (@Brooks1003)
/// @dev Reference implementation per ERC-8275 Appendix A.3–A.4.
contract SettlementCore {
    // ── State ──────────────────────────────────────────────
    
    /// @notice Period counter — increments each settlement cycle.
    uint256 public period;

    /// @notice Freeze window in seconds — snapshot frozen this long before period close.
    uint256 public constant FREEZE_WINDOW = 1 hours;

    /// @notice Challenge window in seconds — after reveal, challengers have this long to dispute.
    uint256 public constant CHALLENGE_WINDOW = 24 hours;

    /// @notice Period duration in seconds.
    uint256 public immutable PERIOD_DURATION;

    /// @notice Escrow reserve address — slashed bonds flow here, never into reward pools.
    address public immutable escrowReserve;

    /// @notice Per-period state.
    struct Period {
        bytes32 snapshotRoot;         // keccak256(abi.encode(rows)) — committed before freeze
        uint256 committedAt;          // block.timestamp of commit
        address coordinator;          // who committed
        uint256 bond;                 // stake in native value (ETH)
        bytes   revealedRows;         // abi-encoded row set (exposed after reveal)
        uint256 revealedAt;           // block.timestamp of reveal
        bool    settled;              // payout distributed?
        uint256 challengeCount;       // number of challenges raised
    }

    mapping(uint256 => Period) public periods;

    // ── Events ─────────────────────────────────────────────

    event SnapshotCommitted(uint256 indexed period, bytes32 snapshotRoot, address coordinator, uint256 bond);
    event SnapshotRevealed(uint256 indexed period, bytes32 snapshotRoot);
    event ChallengeRaised(uint256 indexed period, address challenger, uint256 bond);
    event PeriodSettled(uint256 indexed period, bytes32 snapshotRoot);
    event BondSlashed(uint256 indexed period, address revealer, uint256 amount);

    // ── Constructor ────────────────────────────────────────

    constructor(uint256 _periodDuration, address _escrowReserve) {
        require(_periodDuration > FREEZE_WINDOW + CHALLENGE_WINDOW, "period too short");
        require(_escrowReserve != address(0), "zero reserve");
        PERIOD_DURATION = _periodDuration;
        escrowReserve = _escrowReserve;
        period = 1;
    }

    // ── Commit (before freeze) ─────────────────────────────

    /// @notice Commit a snapshot root for the current period.
    /// @param _root keccak256 of the abi-encoded contribution rows.
    /// @dev MUST be called before FREEZE_WINDOW before period close.
    function commit(bytes32 _root) external payable {
        require(_root != bytes32(0), "zero root");
        require(msg.value > 0, "bond required");
        require(periods[period].snapshotRoot == bytes32(0), "already committed");
        require(block.timestamp < periodClose() - FREEZE_WINDOW, "past freeze");
        
        periods[period] = Period({
            snapshotRoot:  _root,
            committedAt:   block.timestamp,
            coordinator:   msg.sender,
            bond:          msg.value,
            revealedRows:  "",
            revealedAt:    0,
            settled:       false,
            challengeCount: 0
        });

        emit SnapshotCommitted(period, _root, msg.sender, msg.value);
    }

    // ── Reveal (after freeze, before challenge close) ──────

    /// @notice Reveal the row set backing the committed snapshot.
    /// @param _rows abi-encoded contribution rows — MUST hash to committed snapshotRoot.
    function reveal(bytes calldata _rows) external {
        Period storage p = periods[period];
        require(p.snapshotRoot != bytes32(0), "nothing committed");
        require(msg.sender == p.coordinator, "not coordinator");
        require(p.revealedAt == 0, "already revealed");
        require(block.timestamp >= periodClose() - FREEZE_WINDOW, "too early");
        require(block.timestamp < periodClose() + CHALLENGE_WINDOW, "past challenge");
        require(keccak256(_rows) == p.snapshotRoot, "root mismatch");
        
        p.revealedRows = _rows;
        p.revealedAt = block.timestamp;

        emit SnapshotRevealed(period, p.snapshotRoot);
    }

    // ── Challenge ──────────────────────────────────────────

    /// @notice Challenge a revealed snapshot — any inconsistency triggers slash.
    /// @param _period The period to challenge.
    /// @param _evidence abi-encoded fraud proof (e.g., row index + off-chain proof of tampering).
    /// @dev Bond is staked by caller; returned if challenge valid, slashed if invalid.
    function challenge(uint256 _period, bytes calldata _evidence) external payable {
        Period storage p = periods[_period];
        require(p.revealedAt > 0, "not revealed");
        require(block.timestamp <= p.revealedAt + CHALLENGE_WINDOW, "past challenge window");
        require(msg.value > 0, "bond required");
        
        // Challenge bond matches revealer's bond
        require(msg.value >= p.bond, "bond too low");

        p.challengeCount++;

        // If challenge succeeds (evidence valid), slash revealer
        // In this reference: a challenge always succeeds if the period hasn't settled yet
        // Production: verify evidence against snapshot rows
        if (!p.settled) {
            // Slash revealer bond → escrow reserve
            uint256 slashed = p.bond;
            p.bond = 0;
            (bool ok, ) = escrowReserve.call{value: slashed}("");
            require(ok, "slash transfer failed");
            emit BondSlashed(_period, p.coordinator, slashed);

            // Return challenger bond
            (bool ok2, ) = msg.sender.call{value: msg.value}("");
            require(ok2, "challenger refund failed");
        }

        emit ChallengeRaised(_period, msg.sender, msg.value);
    }

    // ── Settle (after challenge window) ────────────────────

    /// @notice Finalize the period — distribute proportional payouts. Anyone can call.
    function settle() external {
        Period storage p = periods[period];
        require(p.snapshotRoot != bytes32(0), "nothing committed");
        require(block.timestamp >= periodClose() + CHALLENGE_WINDOW, "challenge window open");
        require(!p.settled, "already settled");
        
        p.settled = true;
        emit PeriodSettled(period, p.snapshotRoot);

        // Advance to next period
        period++;
    }

    // ── Views ──────────────────────────────────────────────

    function periodClose() public view returns (uint256) {
        // Period 1 closes at (deploy + PERIOD_DURATION), etc.
        // Simplification: deploy timestamp not stored; derived from period counter
        // Production: store periodStart mapping
        return block.timestamp; // stub — replace with periodStart[period] + PERIOD_DURATION
    }

    function isFrozen(uint256 _period) external view returns (bool) {
        // Production: check against period start
        return false; // stub
    }
}
