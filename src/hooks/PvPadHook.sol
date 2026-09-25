// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PvPadConstants} from "../libraries/PvPadConstants.sol";
import {FeeEscrow} from "../FeeEscrow.sol";

interface IPvPadLaunchRegistry {
    function launchCreator(PoolId poolId) external view returns (address);
    function isRegisteredPool(PoolId poolId) external view returns (bool);
}

/// @notice Shared post-graduation swap fee hook. Swap-path only — no beforeInitialize.
contract PvPadHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error NotPoolManager();
    error PartialFill();

    IPoolManager public immutable poolManager;
    IPvPadLaunchRegistry public immutable registry;
    FeeEscrow public immutable feeEscrow;

    constructor(IPoolManager _poolManager, IPvPadLaunchRegistry _registry, FeeEscrow _feeEscrow) {
        poolManager = _poolManager;
        registry = _registry;
        feeEscrow = _feeEscrow;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        if (!registry.isRegisteredPool(id)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // Reject partial fills (launch-139 pattern).
        if (params.sqrtPriceLimitX96 != 0) {
            revert PartialFill();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        if (!registry.isRegisteredPool(id)) {
            return (IHooks.afterSwap.selector, 0);
        }

        address creator = registry.launchCreator(id);
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 magnitude = uint256(uint128(swapAmount));
        uint256 feeAmount = _fee(magnitude);
        if (feeAmount == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        poolManager.take(feeCurrency, address(this), feeAmount);
        _deliverFee(Currency.unwrap(feeCurrency), feeAmount, creator);

        return (IHooks.afterSwap.selector, int128(int256(feeAmount)));
    }

    function _fee(uint256 magnitude) internal pure returns (uint256) {
        if (magnitude < 100) return 0;
        return (magnitude * PvPadConstants.FEE_BPS) / PvPadConstants.BPS_DENOMINATOR;
    }

    function _deliverFee(address currency, uint256 feeAmount, address creator) internal {
        if (currency == address(0)) {
            try feeEscrow.recordTradeFeeNative{value: feeAmount}(creator, feeAmount) {} catch {}
        } else {
            IERC20(currency).forceApprove(address(feeEscrow), feeAmount);
            try feeEscrow.recordTradeFee(creator, currency, feeAmount) {} catch {}
        }
    }

    // ——— Unimplemented hook entrypoints (permissions false; must not be called) ———

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert();
    }

    receive() external payable {}
}
