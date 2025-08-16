// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/security/Pausable.sol";

/**
 * @title PoASubmission
 * @author Nora AI
 * @notice A contract for allowlist-gated, encrypted Proof-of-Action (PoA) submissions.
 *
 * This contract allows a designated owner (the "Organizer") to manage a list of
 * authorized addresses ("Whistleblowers"). These whistleblowers can submit encrypted
 * data payloads, each associated with a unique action identifier to prevent replays.
 *
 * The contract is designed with an "event-first" approach to minimize on-chain storage
 * costs. By default, the full ciphertext of a submission is emitted in an event and not
 * stored in the contract's state. The owner can enable on-chain storage if needed.
 *
 * Key features include:
 * - Allowlist control for submission access.
 * - Replay protection using unique action IDs.
 * - Configurable on-chain vs. event-only storage for submissions.
 * - Pausable functionality to halt new submissions in emergencies.
 * - Administrative controls for managing the allowlist and contract parameters.
 */
contract PoASubmission is Ownable, Pausable {
    // =============================================================
    //                           Storage
    // =============================================================

    /**
     * @dev A submission record. Can be stored on-chain if `storeCiphertextOnChain` is true.
     * @param submitter The address that submitted the action.
     * @param commitment A keccak256 hash of the plaintext action, binding the ciphertext to it.
     * @param ciphertext The encrypted Proof-of-Action payload.
     * @param schemaId An optional identifier for the data schema/version.
     * @param submittedAt The timestamp (block.timestamp) when the submission occurred.
     * @param size The size of the ciphertext in bytes.
     */
    struct Submission {
        address submitter;
        bytes32 commitment;
        bytes ciphertext;
        uint64 schemaId;
        uint64 submittedAt;
        uint32 size;
    }

    /**
     * @notice Maps an address to its allowlist status. Only allowed addresses can submit.
     */
    mapping(address => bool) public allowlist;

    /**
     * @notice Maps an action ID to a boolean indicating if it has been used. Prevents replays.
     */
    mapping(bytes32 => bool) public usedActionId;

    /**
     * @notice If `storeCiphertextOnChain` is true, this maps an action ID to its stored submission data.
     */
    mapping(bytes32 => Submission) private submissions;

    /**
     * @notice The maximum permitted size of the ciphertext payload in bytes.
     */
    uint256 public maxCiphertextBytes;

    /**
     * @notice If true, submission data (including ciphertext) is stored on-chain.
     * If false, ciphertext is only emitted in the `ActionSubmitted` event.
     */
    bool public storeCiphertextOnChain;

    // =============================================================
    //                            Events
    // =============================================================

    event WhistleblowerAllowed(address indexed account, address indexed actor);
    event WhistleblowerRemoved(address indexed account, address indexed actor);
    event ActionSubmitted(
        bytes32 indexed actionId,
        address indexed submitter,
        bytes32 commitment,
        bytes ciphertext,
        uint64 schemaId,
        uint64 submittedAt,
        uint32 size
    );
    event ActionRevoked(bytes32 indexed actionId, address indexed actor, string reason);

    // =============================================================
    //                           Errors
    // =============================================================

    error NotAllowed();
    error InvalidActionId();
    error DuplicateActionId();
    error InvalidCommitment();
    error EmptyCiphertext();
    error CiphertextTooLarge(uint256 actual, uint256 max);
    error NotStored();

    // =============================================================
    //                         Constructor
    // =============================================================

    /**
     * @dev Initializes the contract with an owner and operational parameters.
     * @param initialOwner The address that will have administrative control over the contract.
     * @param _maxCiphertextBytes The initial maximum size for ciphertext submissions.
     * @param _storeCiphertextOnChain The initial policy for storing submission data on-chain.
     */
    constructor(
        address initialOwner,
        uint256 _maxCiphertextBytes,
        bool _storeCiphertextOnChain
    ) Ownable(initialOwner) {
        maxCiphertextBytes = _maxCiphertextBytes;
        storeCiphertextOnChain = _storeCiphertextOnChain;
    }

    // =============================================================
    //                     Public/External Logic
    // =============================================================

    /**
     * @notice Submits an encrypted Proof-of-Action.
     * @dev The caller must be on the allowlist. The contract must not be paused.
     * Validates inputs, marks the actionId as used, emits an event, and optionally stores the data.
     * @param actionId A unique identifier for the action to prevent replay attacks.
     * @param commitment A keccak256 hash of the plaintext corresponding to the ciphertext.
     * @param ciphertext The encrypted data payload.
     * @param schemaId An optional version identifier for the data schema.
     */
    function submit(
        bytes32 actionId,
        bytes32 commitment,
        bytes calldata ciphertext,
        uint64 schemaId
    ) external whenNotPaused {
        // Validation checks
        if (!allowlist[msg.sender]) revert NotAllowed();
        if (actionId == bytes32(0)) revert InvalidActionId();
        if (usedActionId[actionId]) revert DuplicateActionId();
        if (commitment == bytes32(0)) revert InvalidCommitment();

        uint256 ciphertextLen = ciphertext.length;
        if (ciphertextLen == 0) revert EmptyCiphertext();
        if (ciphertextLen > maxCiphertextBytes) {
            revert CiphertextTooLarge(ciphertextLen, maxCiphertextBytes);
        }

        // Mark action as used
        usedActionId[actionId] = true;

        uint64 submittedAt = uint64(block.timestamp);
        uint32 size = uint32(ciphertextLen);

        // Store submission if configured
        if (storeCiphertextOnChain) {
            submissions[actionId] = Submission({
                submitter: msg.sender,
                commitment: commitment,
                ciphertext: ciphertext,
                schemaId: schemaId,
                submittedAt: submittedAt,
                size: size
            });
        }

        // Emit event regardless of storage configuration
        emit ActionSubmitted(
            actionId,
            msg.sender,
            commitment,
            ciphertext,
            schemaId,
            submittedAt,
            size
        );
    }

    // =============================================================
    //                        View Functions
    // =============================================================

    /**
     * @notice Checks if an address is on the submission allowlist.
     * @param account The address to check.
     * @return True if the address is allowed, false otherwise.
     */
    function isAllowed(address account) external view returns (bool) {
        return allowlist[account];
    }

    /**
     * @notice Retrieves a submission from on-chain storage.
     * @dev This function will revert if `storeCiphertextOnChain` is false.
     * @param actionId The ID of the submission to retrieve.
     * @return The full Submission struct.
     */
    function getSubmission(bytes32 actionId) external view returns (Submission memory) {
        if (!storeCiphertextOnChain) revert NotStored();
        return submissions[actionId];
    }

    // =============================================================
    //                      Admin Functions
    // =============================================================

    /**
     * @notice Adds an address to the whistleblower allowlist.
     * @dev Can only be called by the owner. Emits a `WhistleblowerAllowed` event.
     * @param account The address to add to the allowlist.
     */
    function allowWhistleblower(address account) external onlyOwner {
        allowlist[account] = true;
        emit WhistleblowerAllowed(account, msg.sender);
    }

    /**
     * @notice Removes an address from the whistleblower allowlist.
     * @dev Can only be called by the owner. Emits a `WhistleblowerRemoved` event.
     * @param account The address to remove from the allowlist.
     */
    function removeWhistleblower(address account) external onlyOwner {
        allowlist[account] = false;
        emit WhistleblowerRemoved(account, msg.sender);
    }

    /**
     * @notice Sets the maximum allowed size for ciphertext.
     * @dev Can only be called by the owner.
     * @param newLimit The new maximum size in bytes.
     */
    function setMaxCiphertextBytes(uint256 newLimit) external onlyOwner {
        maxCiphertextBytes = newLimit;
    }

    /**
     * @notice Sets the policy for storing ciphertext on-chain.
     * @dev Can only be called by the owner. This is a significant policy change
     * and should be done with caution.
     * @param enabled True to enable on-chain storage, false to disable it.
     */
    function setStoreCiphertextOnChain(bool enabled) external onlyOwner {
        storeCiphertextOnChain = enabled;
    }

    /**
     * @notice Pauses the contract, preventing new submissions.
     * @dev Can only be called by the owner. Read functions are unaffected.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, re-enabling new submissions.
     * @dev Can only be called by the owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Administratively revokes an action, emitting an event for off-chain indexers.
     * @dev Can only be called by the owner. This is a soft-delete and does not alter storage.
     * @param actionId The ID of the action to revoke.
     * @param reason A description of why the action is being revoked.
     */
    function revokeAction(bytes32 actionId, string calldata reason) external onlyOwner {
        emit ActionRevoked(actionId, msg.sender, reason);
    }
}
