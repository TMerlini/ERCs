// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * BountySettlement — ERC-8263 / OCP proof-of-concept
 *
 * Flow:
 *   1. Poster calls postBounty(inputHash) with ETH reward
 *   2. Agent executes off-chain → gateway anchors inputHash (L3 OCP) + signs L4 EIP-712 attestation
 *   3. Claimant fetches struct fields + signature from gateway.ensub.org/agent/verify/:inputHash
 *   4. Claimant calls claimBounty(...) — contract verifies the L4 EIP-712 signature
 *   5. If valid: reward transfers to claimant
 *
 * Verification: the gateway's EIP-712 InferenceAttestation signature already encodes
 * input_hash — no oracle needed. Contract recovers the signer and checks it matches
 * the known gateway attestor (GATEWAY_ATTESTOR). In production this would call
 * registry.getAgentWallet(agentId) via CCIP Read for a trustless signer lookup.
 */
contract BountySettlement {

    // ── EIP-712 type hashes ────────────────────────────────────────────────────
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "InferenceAttestation(bytes32 raw_input_hash,bytes32 sanitization_pipeline_hash,bytes32 input_hash,bytes32 output_hash,bytes32 manifest_hash,uint256 agentId,address registry,uint64 timestamp)"
    );

    // ── Gateway attestor — dinamic.eth gateway key (also ERC-8004 hot wallet) ─
    // Production: replace with registry.getAgentWallet(agentId) via CCIP Read
    address public constant GATEWAY_ATTESTOR = 0x85Fa13511D170FBe173761b63D7f8DD4A6f6Bf1A;

    // ── EIP-712 domain parameters matching attestation.ts ─────────────────────
    // name: "KYA-L4", version: "1", chainId: 1 (Ethereum mainnet registry), verifyingContract: registry
    string  private constant DOMAIN_NAME    = "KYA-L4";
    string  private constant DOMAIN_VERSION = "1";
    uint256 private constant DOMAIN_CHAIN_ID = 1; // Ethereum mainnet — where ERC-8004 registries live

    // ── Storage ────────────────────────────────────────────────────────────────
    struct Bounty {
        address poster;
        uint256 reward;
        bool    claimed;
    }

    mapping(bytes32 => Bounty) public bounties;

    // ── Events ─────────────────────────────────────────────────────────────────
    event BountyPosted(bytes32 indexed inputHash, address indexed poster, uint256 reward);
    event BountyClaimed(bytes32 indexed inputHash, address indexed claimant, uint256 reward);

    // ── Post a bounty for a specific inputHash ─────────────────────────────────
    function postBounty(bytes32 inputHash) external payable {
        require(msg.value > 0, "BountySettlement: no reward");
        require(bounties[inputHash].poster == address(0), "BountySettlement: already posted");
        bounties[inputHash] = Bounty(msg.sender, msg.value, false);
        emit BountyPosted(inputHash, msg.sender, msg.value);
    }

    // ── Claim a bounty by submitting the L4 EIP-712 attestation ───────────────
    function claimBounty(
        bytes32 rawInputHash,
        bytes32 sanitizationPipelineHash,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 manifestHash,
        uint256 agentId,
        address registry,
        uint64  timestamp,
        bytes calldata signature
    ) external {
        Bounty storage bounty = bounties[inputHash];
        require(bounty.poster != address(0), "BountySettlement: bounty not found");
        require(!bounty.claimed,             "BountySettlement: already claimed");

        // Reconstruct EIP-712 digest — must match exactly what attestation.ts signed
        bytes32 domainSeparator = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(DOMAIN_NAME)),
            keccak256(bytes(DOMAIN_VERSION)),
            DOMAIN_CHAIN_ID,
            registry
        ));

        bytes32 structHash = keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            rawInputHash,
            sanitizationPipelineHash,
            inputHash,
            outputHash,
            manifestHash,
            agentId,
            registry,
            timestamp
        ));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address signer = _recover(digest, signature);
        require(signer == GATEWAY_ATTESTOR, "BountySettlement: invalid attestation");

        bounty.claimed = true;
        uint256 reward = bounty.reward;
        emit BountyClaimed(inputHash, msg.sender, reward);

        (bool ok,) = msg.sender.call{value: reward}("");
        require(ok, "BountySettlement: transfer failed");
    }

    // ── ECDSA recovery ─────────────────────────────────────────────────────────
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "BountySettlement: invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(digest, v, r, s);
    }
}

