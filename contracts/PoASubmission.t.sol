// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PoASubmission} from "../contracts/PoASubmission.sol";

contract PoASubmissionTest is Test {
    // =============================================================
    //                           Test Setup
    // =============================================================

    PoASubmission internal poa;

    // Actors
    address internal owner = makeAddr("owner");
    address internal whistleblower1 = makeAddr("whistleblower1");
    address internal whistleblower2 = makeAddr("whistleblower2");
    address internal unauthorized = makeAddr("unauthorized");

    // Default Parameters
    uint256 internal constant MAX_CIPHERTEXT_BYTES = 4096;
    bool internal constant STORE_CIPHERTEXT_ON_CHAIN = true;

    // Test Data
    bytes32 internal actionId1 = keccak256("action-1");
    bytes32 internal commitment1 = keccak256("plaintext-1");
    bytes internal ciphertext1 = "encrypted-data-1";
    uint64 internal schemaId1 = 1;

    function setUp() public {
        vm.startPrank(owner);
        poa = new PoASubmission(owner, MAX_CIPHERTEXT_BYTES, STORE_CIPHERTEXT_ON_CHAIN);
        vm.stopPrank();
    }

    // =============================================================
    //                      Constructor Tests
    // =============================================================

    function test_initial_state() public {
        assertEq(poa.owner(), owner, "Owner should be set correctly");
        assertEq(
            poa.maxCiphertextBytes(),
            MAX_CIPHERTEXT_BYTES,
            "maxCiphertextBytes should be set"
        );
        assertEq(
            poa.storeCiphertextOnChain(),
            STORE_CIPHERTEXT_ON_CHAIN,
            "storeCiphertextOnChain should be set"
        );
        assertFalse(poa.paused(), "Contract should not be paused initially");
    }

    // =============================================================
    //                  Allowlist Management Tests
    // =============================================================

    function test_allowWhistleblower() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);
        assertTrue(poa.allowlist(whistleblower1), "Whistleblower should be allowlisted");
    }

    function test_allowWhistleblower_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PoASubmission.WhistleblowerAllowed(whistleblower1, owner);
        poa.allowWhistleblower(whistleblower1);
    }

    function test_fail_allowWhistleblower_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(PoASubmission.OwnableUnauthorizedAccount.selector, unauthorized));
        poa.allowWhistleblower(whistleblower1);
    }

    function test_removeWhistleblower() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);
        poa.removeWhistleblower(whistleblower1);
        assertFalse(poa.allowlist(whistleblower1), "Whistleblower should be removed");
    }

    function test_removeWhistleblower_emitsEvent() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.expectEmit(true, true, true, true);
        emit PoASubmission.WhistleblowerRemoved(whistleblower1, owner);
        poa.removeWhistleblower(whistleblower1);
    }

    function test_fail_removeWhistleblower_notOwner() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(PoASubmission.OwnableUnauthorizedAccount.selector, unauthorized));
        poa.removeWhistleblower(whistleblower1);
    }

    // =============================================================
    //                      Submission Tests
    // =============================================================

    function test_submit_happyPath_storageOn() public {
        // Setup
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        // Submit
        vm.prank(whistleblower1);
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);

        // Assert state
        assertTrue(poa.usedActionId(actionId1), "Action ID should be marked as used");

        PoASubmission.Submission memory s = poa.getSubmission(actionId1);
        assertEq(s.submitter, whistleblower1, "Submitter mismatch");
        assertEq(s.commitment, commitment1, "Commitment mismatch");
        assertEq(s.ciphertext, ciphertext1, "Ciphertext mismatch");
        assertEq(s.schemaId, schemaId1, "Schema ID mismatch");
        assertEq(uint32(s.size), uint32(ciphertext1.length), "Size mismatch");
        assertTrue(s.submittedAt > 0, "Timestamp should be set");
    }

    function test_submit_happyPath_emitsEvent() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(whistleblower1);
        vm.expectEmit(true, true, false, true); // Loosely check ciphertext
        emit PoASubmission.ActionSubmitted(
            actionId1,
            whistleblower1,
            commitment1,
            ciphertext1,
            schemaId1,
            block.timestamp,
            uint32(ciphertext1.length)
        );
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);
    }

    function test_submit_happyPath_storageOff() public {
        // Setup
        vm.startPrank(owner);
        PoASubmission noStorePoa = new PoASubmission(owner, MAX_CIPHERTEXT_BYTES, false);
        noStorePoa.allowWhistleblower(whistleblower1);
        vm.stopPrank();

        // Submit
        vm.prank(whistleblower1);
        noStorePoa.submit(actionId1, commitment1, ciphertext1, schemaId1);

        // Assert state
        assertTrue(noStorePoa.usedActionId(actionId1), "Action ID should be marked as used");

        // Assert that getSubmission reverts
        vm.expectRevert(PoASubmission.NotStored.selector);
        noStorePoa.getSubmission(actionId1);
    }


    // =============================================================
    //                  Submission Validation Tests
    // =============================================================

    function test_fail_submit_notAllowed() public {
        vm.prank(unauthorized);
        vm.expectRevert(PoASubmission.NotAllowed.selector);
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);
    }

    function test_fail_submit_duplicateActionId() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(whistleblower1);
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);

        vm.prank(whistleblower1); // Try again
        vm.expectRevert(PoASubmission.DuplicateActionId.selector);
        poa.submit(actionId1, commitment1, "different-data", schemaId1);
    }

    function test_fail_submit_invalidActionId() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(whistleblower1);
        vm.expectRevert(PoASubmission.InvalidActionId.selector);
        poa.submit(bytes32(0), commitment1, ciphertext1, schemaId1);
    }

    function test_fail_submit_invalidCommitment() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(whistleblower1);
        vm.expectRevert(PoASubmission.InvalidCommitment.selector);
        poa.submit(actionId1, bytes32(0), ciphertext1, schemaId1);
    }

    function test_fail_submit_emptyCiphertext() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);

        vm.prank(whistleblower1);
        vm.expectRevert(PoASubmission.EmptyCiphertext.selector);
        poa.submit(actionId1, commitment1, "", schemaId1);
    }

    function test_fail_submit_ciphertextTooLarge() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);
        poa.setMaxCiphertextBytes(10);

        bytes memory largeCiphertext = "this-is-way-too-long";

        vm.prank(whistleblower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoASubmission.CiphertextTooLarge.selector,
                largeCiphertext.length,
                10
            )
        );
        poa.submit(actionId1, commitment1, largeCiphertext, schemaId1);
    }

    // =============================================================
    //                       Pausable Tests
    // =============================================================

    function test_fail_submit_whenPaused() public {
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);
        poa.pause();

        vm.prank(whistleblower1);
        vm.expectRevert(abi.encodeWithSelector(PoASubmission.EnforcedPause.selector));
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);
    }

    function test_unpause_allowsSubmissions() public {
        // Pause and unpause
        vm.prank(owner);
        poa.allowWhistleblower(whistleblower1);
        poa.pause();
        poa.unpause();

        // Should be able to submit again
        vm.prank(whistleblower1);
        poa.submit(actionId1, commitment1, ciphertext1, schemaId1);
        assertTrue(poa.usedActionId(actionId1));
    }

    // =============================================================
    //                   Admin Function Tests
    // =============================================================

    function test_setMaxCiphertextBytes() public {
        uint256 newLimit = 8192;
        vm.prank(owner);
        poa.setMaxCiphertextBytes(newLimit);
        assertEq(poa.maxCiphertextBytes(), newLimit, "Limit should be updated");
    }

    function test_setStoreCiphertextOnChain() public {
        vm.prank(owner);
        poa.setStoreCiphertextOnChain(false);
        assertFalse(poa.storeCiphertextOnChain(), "Storage flag should be updated");
    }

    function test_revokeAction_emitsEvent() public {
        string memory reason = "Compromised data";
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit PoASubmission.ActionRevoked(actionId1, owner, reason);
        poa.revokeAction(actionId1, reason);
    }
}