// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KingOfThePad} from "./KingOfThePad.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Pullable credits for king beneficiary and per-launch creators. Non-reverting fee delivery.
contract FeeEscrow {
    using SafeERC20 for IERC20;

    error NotAuthorized();

    KingOfThePad public immutable kingOfThePad;

    address public factory;
    address public hook;

    /// @dev ETH uses address(0) as currency key.
    mapping(address currency => mapping(address account => uint256 amount)) public pending;

    /// @dev Platform share accrued before the first king claim.
    uint256 public unassignedEth;
    mapping(address token => uint256) public unassignedToken;

    uint256 public totalSkimmedEth;
    mapping(address token => uint256) public totalSkimmedToken;

    mapping(address => bool) public authorizedRecorders;

    event FeeCredited(address indexed account, address indexed currency, uint256 amount, bool isKingShare);
    event FeeWithdrawn(address indexed account, address indexed currency, uint256 amount);

    constructor(KingOfThePad _king) {
        kingOfThePad = _king;
    }

    function configure(address _factory, address _hook) external {
        require(factory == address(0), "CONFIGURED");
        factory = _factory;
        hook = _hook;
        authorizedRecorders[_hook] = true;
    }

    function authorizeRecorder(address recorder, bool allowed) external {
        require(msg.sender == factory, "NOT_FACTORY");
        authorizedRecorders[recorder] = allowed;
    }

    modifier onlyRecorder() {
        if (!authorizedRecorders[msg.sender]) revert NotAuthorized();
        _;
    }

    function recordTradeFee(address creator, address currency, uint256 feeAmount)
        external
        payable
        onlyRecorder
    {
        if (feeAmount == 0) return;
        if (currency == address(0)) {
            require(msg.value == feeAmount, "FEE_MISMATCH");
        }

        uint256 kingShare = (feeAmount * PvPadConstants.KING_CREATOR_SPLIT_BPS) / PvPadConstants.BPS_DENOMINATOR;
        uint256 creatorShare = feeAmount - kingShare;

        if (currency == address(0)) {
            totalSkimmedEth += feeAmount;
            _creditKingEth(kingShare);
            _creditEth(creator, creatorShare);
        } else {
            IERC20(currency).safeTransferFrom(msg.sender, address(this), feeAmount);
            totalSkimmedToken[currency] += feeAmount;
            _creditKingToken(currency, kingShare);
            _creditToken(creator, currency, creatorShare);
        }
    }

    function recordTradeFeeNative(address creator, uint256 feeAmount) external payable onlyRecorder {
        require(msg.value == feeAmount, "FEE_MISMATCH");
        if (feeAmount == 0) return;

        uint256 kingShare = (feeAmount * PvPadConstants.KING_CREATOR_SPLIT_BPS) / PvPadConstants.BPS_DENOMINATOR;
        uint256 creatorShare = feeAmount - kingShare;
        totalSkimmedEth += feeAmount;
        _creditKingEth(kingShare);
        _creditEth(creator, creatorShare);
    }

    function withdraw(address currency, address to) external returns (uint256 amount) {
        amount = pending[currency][msg.sender];
        if (amount == 0) return 0;
        pending[currency][msg.sender] = 0;

        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                pending[currency][msg.sender] = amount;
                return 0;
            }
        } else {
            try IERC20(currency).transfer(to, amount) returns (bool success) {
                if (!success) {
                    pending[currency][msg.sender] = amount;
                    return 0;
                }
            } catch {
                pending[currency][msg.sender] = amount;
                return 0;
            }
        }
        emit FeeWithdrawn(msg.sender, currency, amount);
    }

    function assignUnassigned() external {
        address ben = kingOfThePad.beneficiary();
        require(ben != address(0), "NO_BENEFICIARY");
        uint256 ethAmt = unassignedEth;
        if (ethAmt > 0) {
            unassignedEth = 0;
            pending[address(0)][ben] += ethAmt;
            emit FeeCredited(ben, address(0), ethAmt, true);
        }
    }

    function _creditKingEth(uint256 amount) internal {
        if (amount == 0) return;
        address ben = kingOfThePad.beneficiary();
        if (ben == address(0) || kingOfThePad.claimCount() == 0) {
            unassignedEth += amount;
            return;
        }
        pending[address(0)][ben] += amount;
        emit FeeCredited(ben, address(0), amount, true);
    }

    function _creditKingToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        address ben = kingOfThePad.beneficiary();
        if (ben == address(0) || kingOfThePad.claimCount() == 0) {
            unassignedToken[token] += amount;
            return;
        }
        pending[token][ben] += amount;
        emit FeeCredited(ben, token, amount, true);
    }

    function _creditEth(address account, uint256 amount) internal {
        if (amount == 0) return;
        pending[address(0)][account] += amount;
        emit FeeCredited(account, address(0), amount, false);
    }

    function _creditToken(address account, address token, uint256 amount) internal {
        if (amount == 0) return;
        pending[token][account] += amount;
        emit FeeCredited(account, token, amount, false);
    }

    receive() external payable {}
}
