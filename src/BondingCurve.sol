// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";
import {FeeEscrow} from "./FeeEscrow.sol";

interface IPvPadFactoryCurve {
    function feeEscrow() external view returns (FeeEscrow);
    function graduationThreshold() external view returns (uint256);
}

/// @notice Per-launch constant-product bonding curve with virtual reserves (x*y=k).
/// @dev x = VIRTUAL_TOKEN + tokenReserve, y = VIRTUAL_ETH + ethReserve.
contract BondingCurve {
    using SafeERC20 for IERC20;

    error Graduated();
    error ZeroAmount();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error NotFactory();

    event Bought(address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 fee, uint256 ethOut);

    IERC20 public immutable token;
    IPvPadFactoryCurve public immutable factory;
    uint256 public immutable launchId;
    address public immutable creator;

    bool public graduated;
    uint256 public ethReserve;
    uint256 public tokenReserve;

    constructor(IERC20 _token, IPvPadFactoryCurve _factory, uint256 _launchId, address _creator) {
        token = _token;
        factory = _factory;
        launchId = _launchId;
        creator = _creator;
        tokenReserve = PvPadConstants.TOKEN_SUPPLY;
    }

    function readyToGraduate() public view returns (bool) {
        return !graduated && ethReserve >= factory.graduationThreshold();
    }

    function getReserves() external view returns (uint256 ethR, uint256 tokenR) {
        return (ethReserve, tokenReserve);
    }

    function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut, uint256 fee) {
        if (graduated || ethIn == 0) return (0, 0);
        fee = _fee(ethIn);
        uint256 ethForCurve = ethIn - fee;
        tokensOut = _tokensOutForEth(ethForCurve);
    }

    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut, uint256 fee) {
        if (graduated || tokensIn == 0) return (0, 0);
        uint256 grossEth = _ethOutForTokens(tokensIn);
        fee = _fee(grossEth);
        ethOut = grossEth - fee;
    }

    function buy(address recipient) external payable returns (uint256 tokensOut) {
        if (graduated) revert Graduated();
        if (msg.value == 0) revert ZeroAmount();

        uint256 fee = _fee(msg.value);
        uint256 ethForCurve = msg.value - fee;
        tokensOut = _tokensOutForEth(ethForCurve);
        if (tokensOut == 0) revert InsufficientOutput();

        ethReserve += ethForCurve;
        tokenReserve -= tokensOut;

        if (fee > 0) {
            factory.feeEscrow().recordTradeFeeNative{value: fee}(creator, fee);
        }

        token.safeTransfer(recipient, tokensOut);
        emit Bought(recipient, msg.value, fee, tokensOut);
    }

    function sell(uint256 tokenAmount, address recipient) external returns (uint256 ethOut) {
        if (graduated) revert Graduated();
        if (tokenAmount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 grossEth = _ethOutForTokens(tokenAmount);
        if (grossEth == 0) revert InsufficientOutput();

        uint256 fee = _fee(grossEth);
        ethOut = grossEth - fee;

        ethReserve -= grossEth;
        tokenReserve += tokenAmount;

        if (fee > 0) {
            factory.feeEscrow().recordTradeFeeNative{value: fee}(creator, fee);
        }

        (bool ok,) = recipient.call{value: ethOut}("");
        require(ok, "ETH_SEND_FAIL");
        emit Sold(msg.sender, tokenAmount, fee, ethOut);
    }

    function markGraduated() external {
        if (msg.sender != address(factory)) revert NotFactory();
        graduated = true;
    }

    function sweepForGraduation() external returns (uint256 ethAmount, uint256 tokenAmount) {
        if (msg.sender != address(factory)) revert NotFactory();
        graduated = true;
        ethAmount = ethReserve;
        tokenAmount = tokenReserve;
        ethReserve = 0;
        tokenReserve = 0;
        if (tokenAmount > 0) {
            token.safeTransfer(address(factory), tokenAmount);
        }
        if (ethAmount > 0) {
            (bool ok,) = address(factory).call{value: ethAmount}("");
            require(ok, "ETH_XFER");
        }
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        if (amount < 100) return 0;
        return (amount * PvPadConstants.FEE_BPS) / PvPadConstants.BPS_DENOMINATOR;
    }

    function _tokensOutForEth(uint256 ethIn) internal view returns (uint256) {
        uint256 x = PvPadConstants.VIRTUAL_TOKEN + tokenReserve;
        uint256 y = PvPadConstants.VIRTUAL_ETH + ethReserve;
        uint256 k = x * y;
        uint256 newY = y + ethIn;
        uint256 newX = k / newY;
        if (newX >= x) return 0;
        return x - newX;
    }

    function _ethOutForTokens(uint256 tokensIn) internal view returns (uint256) {
        uint256 x = PvPadConstants.VIRTUAL_TOKEN + tokenReserve;
        uint256 y = PvPadConstants.VIRTUAL_ETH + ethReserve;
        uint256 k = x * y;
        uint256 newX = x + tokensIn;
        uint256 newY = k / newX;
        if (newY >= y) return 0;
        return y - newY;
    }

    receive() external payable {}
}
