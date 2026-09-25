// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice ETH worker pot funded by launch fees, king bids, and donations. Merkle epochs only.
contract WorkerSubsidy {
    error NotUpdater();
    error InvalidWindow();
    error EpochNotOpen();
    error InvalidProof();
    error AlreadyClaimed();
    error NothingToFund();
    error NoPendingUpdater();

    event Funded(address indexed from, uint256 amount);
    event EpochOpened(uint256 indexed epochId, bytes32 root, uint256 budget, uint256 windowStart, uint256 windowEnd);
    event WorkerClaimed(uint256 indexed epochId, address indexed payee, uint256 amount);
    event UpdaterProposed(address indexed pending);
    event UpdaterAccepted(address indexed updater);

    address public updater;
    address public pendingUpdater;

    uint256 public workerPot;
    uint256 public currentEpoch;

    struct Epoch {
        bytes32 root;
        uint256 budget;
        uint256 paid;
        uint256 windowStart;
        uint256 windowEnd;
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;

    constructor() {
        updater = PvPadConstants.INITIAL_UPDATER;
    }

    receive() external payable {
        fundWorkers();
    }

    function fundWorkers() public payable {
        if (msg.value == 0) revert NothingToFund();
        workerPot += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    function proposeUpdater(address newUpdater) external {
        if (msg.sender != updater) revert NotUpdater();
        pendingUpdater = newUpdater;
        emit UpdaterProposed(newUpdater);
    }

    function acceptUpdater() external {
        if (msg.sender != pendingUpdater) revert NoPendingUpdater();
        updater = pendingUpdater;
        pendingUpdater = address(0);
        emit UpdaterAccepted(updater);
    }

    /// @dev Leaf = keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))))
    function leaf(uint256 epochId, address payee, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))));
    }

    function setEpoch(bytes32 root, uint256 windowStart, uint256 windowEnd) external {
        if (msg.sender != updater) revert NotUpdater();
        if (windowEnd <= windowStart || windowEnd - windowStart > PvPadConstants.MAX_EPOCH_WINDOW) {
            revert InvalidWindow();
        }
        if (workerPot == 0) revert NothingToFund();

        uint256 budget = workerPot;
        workerPot = 0;

        uint256 epochId = ++currentEpoch;
        epochs[epochId] = Epoch({root: root, budget: budget, paid: 0, windowStart: windowStart, windowEnd: windowEnd});
        emit EpochOpened(epochId, root, budget, windowStart, windowEnd);
    }

    function claimWorker(uint256 epochId, address payee, uint256 amount, bytes32[] calldata proof) external {
        Epoch storage e = epochs[epochId];
        if (e.root == bytes32(0)) revert EpochNotOpen();
        if (block.timestamp < e.windowStart || block.timestamp > e.windowEnd) revert EpochNotOpen();
        if (claimed[epochId][payee]) revert AlreadyClaimed();
        if (e.paid + amount > e.budget) revert InvalidProof();

        bytes32 l = leaf(epochId, payee, amount);
        if (!MerkleProof.verify(proof, e.root, l)) revert InvalidProof();

        claimed[epochId][payee] = true;
        e.paid += amount;

        (bool ok,) = payee.call{value: amount}("");
        require(ok, "TRANSFER_FAIL");
        emit WorkerClaimed(epochId, payee, amount);
    }
}
