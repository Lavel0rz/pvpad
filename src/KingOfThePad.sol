// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WorkerSubsidy} from "./WorkerSubsidy.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice King of the Pad: highest bidder sets the platform fee beneficiary. Bids fund workers.
contract KingOfThePad {
    error BidTooLow();

    event KingClaimed(address indexed king, address indexed beneficiary, uint256 paid, uint256 newClaimPrice);

    WorkerSubsidy public immutable workerSubsidy;

    address public king;
    address public beneficiary;
    uint256 public claimPrice;
    uint256 public claimCount;

    constructor(WorkerSubsidy _workerSubsidy) {
        workerSubsidy = _workerSubsidy;
        claimPrice = PvPadConstants.INITIAL_CLAIM_PRICE;
    }

    function claimKing(address _beneficiary) external payable {
        if (msg.value <= claimPrice) revert BidTooLow();

        king = msg.sender;
        beneficiary = _beneficiary;
        claimCount++;

        uint256 bid = msg.value;
        // 100% of bid → worker pot (no refund to prior king).
        workerSubsidy.fundWorkers{value: bid}();

        claimPrice = (claimPrice * (PvPadConstants.BPS_DENOMINATOR + PvPadConstants.KING_BUMP_BPS))
            / PvPadConstants.BPS_DENOMINATOR;

        emit KingClaimed(msg.sender, _beneficiary, bid, claimPrice);
    }
}
