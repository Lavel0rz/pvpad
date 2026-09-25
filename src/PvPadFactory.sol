// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PvPadToken} from "./PvPadToken.sol";
import {BondingCurve, IPvPadFactoryCurve} from "./BondingCurve.sol";
import {FeeEscrow} from "./FeeEscrow.sol";
import {KingOfThePad} from "./KingOfThePad.sol";
import {WorkerSubsidy} from "./WorkerSubsidy.sol";
import {PvPadHook} from "./hooks/PvPadHook.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Permissionless launchpad factory: token + curve per launch, graduate → locked v4 pool.
contract PvPadFactory {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    error LaunchFeeRequired();
    error UnknownLaunch();
    error NotReady();
    error AlreadyGraduated();
    error HookNotSet();
    error ZeroAddress();
    error GenesisExists();
    error HookAlreadySet();

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address token,
        address curve,
        string name,
        string symbol
    );
    event Graduated(uint256 indexed launchId, PoolId poolId, uint160 sqrtPriceX96);

    struct Launch {
        address creator;
        address token;
        address curve;
        bool graduated;
        PoolId poolId;
    }

    /// @dev LP positions are credited here; contract cannot remove liquidity (no unlock entry).
    address public constant LP_LOCK = address(0xdead);

    IPoolManager public immutable poolManager;
    WorkerSubsidy public immutable workerSubsidy;
    KingOfThePad public immutable kingOfThePad;
    FeeEscrow public immutable feeEscrow;
    PvPadHook public hook;

    uint256 public launchFee = PvPadConstants.DEFAULT_LAUNCH_FEE;
    uint256 public graduationThreshold = PvPadConstants.GRADUATION_THRESHOLD;
    uint256 public launchCount;

    mapping(uint256 => Launch) public launches;
    mapping(PoolId => bool) public registeredPool;
    mapping(PoolId => address) public poolCreator;
    mapping(address => bool) public isBondingCurve;

    constructor(
        IPoolManager _poolManager,
        WorkerSubsidy _workerSubsidy,
        KingOfThePad _king,
        FeeEscrow _feeEscrow
    ) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        workerSubsidy = _workerSubsidy;
        kingOfThePad = _king;
        feeEscrow = _feeEscrow;
    }

    function setHook(PvPadHook _hook) external {
        if (address(hook) != address(0)) revert HookAlreadySet();
        hook = _hook;
        feeEscrow.configure(address(this), address(_hook));
    }

    function isRegisteredPool(PoolId poolId) external view returns (bool) {
        return registeredPool[poolId];
    }

    function launchCreator(PoolId poolId) external view returns (address) {
        return poolCreator[poolId];
    }

    /// @dev Genesis launch #0: Pepe Values Pepe / PVP, zero fee.
    function bootstrapGenesis() external returns (uint256 launchId) {
        if (launchCount != 0) revert GenesisExists();
        launchId = _createLaunch(msg.sender, "Pepe Values Pepe", "PVP");
    }

    function createLaunch(string calldata name, string calldata symbol) external payable returns (uint256 launchId) {
        if (msg.value < launchFee) revert LaunchFeeRequired();
        workerSubsidy.fundWorkers{value: launchFee}();
        if (msg.value > launchFee) {
            (bool ok,) = msg.sender.call{value: msg.value - launchFee}("");
            require(ok);
        }
        launchId = _createLaunch(msg.sender, name, symbol);
    }

    function _createLaunch(address creator, string memory name, string memory symbol)
        internal
        returns (uint256 launchId)
    {
        launchId = launchCount++;
        PvPadToken token = new PvPadToken(name, symbol);
        BondingCurve curve = new BondingCurve(IERC20(address(token)), IPvPadFactoryCurve(address(this)), launchId, creator);
        IERC20(address(token)).safeTransfer(address(curve), IERC20(address(token)).balanceOf(address(this)));
        isBondingCurve[address(curve)] = true;
        feeEscrow.authorizeRecorder(address(curve), true);

        launches[launchId] = Launch({
            creator: creator,
            token: address(token),
            curve: address(curve),
            graduated: false,
            poolId: PoolId.wrap(0)
        });

        emit LaunchCreated(launchId, creator, address(token), address(curve), name, symbol);
    }

    function graduate(uint256 launchId) external returns (PoolId poolId) {
        if (address(hook) == address(0)) revert HookNotSet();
        Launch storage L = launches[launchId];
        if (L.curve == address(0)) revert UnknownLaunch();
        if (L.graduated) revert AlreadyGraduated();

        BondingCurve curve = BondingCurve(payable(L.curve));
        if (!curve.readyToGraduate()) revert NotReady();

        (uint256 ethAmount, uint256 tokenAmount) = curve.sweepForGraduation();

        Currency currency0;
        Currency currency1;
        if (Currency.wrap(address(0)) < Currency.wrap(L.token)) {
            currency0 = Currency.wrap(address(0));
            currency1 = Currency.wrap(L.token);
        } else {
            currency0 = Currency.wrap(L.token);
            currency1 = Currency.wrap(address(0));
        }

        uint160 sqrtPriceX96 = _sqrtPriceFromAmounts(
            currency0, currency1, tokenAmount, ethAmount, L.token
        );

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: PvPadConstants.POOL_FEE,
            tickSpacing: PvPadConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        poolId = key.toId();
        poolManager.initialize(key, sqrtPriceX96);

        poolManager.unlock(
            abi.encode(
                GraduateData({
                    key: key,
                    ethAmount: ethAmount,
                    tokenAmount: tokenAmount,
                    token: L.token,
                    launchId: launchId
                })
            )
        );

        L.graduated = true;
        L.poolId = poolId;
        registeredPool[poolId] = true;
        poolCreator[poolId] = L.creator;

        emit Graduated(launchId, poolId, sqrtPriceX96);
    }

    struct GraduateData {
        PoolKey key;
        uint256 ethAmount;
        uint256 tokenAmount;
        address token;
        uint256 launchId;
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        GraduateData memory data = abi.decode(rawData, (GraduateData));

        uint256 amount0;
        uint256 amount1;
        if (data.key.currency0.isAddressZero()) {
            amount0 = data.ethAmount;
            amount1 = data.tokenAmount;
        } else {
            amount0 = data.tokenAmount;
            amount1 = data.ethAmount;
        }

        int24 tickLower = TickMath.minUsableTick(PvPadConstants.POOL_TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(PvPadConstants.POOL_TICK_SPACING);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, data.key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(uint256(data.launchId))
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, params, "");

        if (delta.amount0() < 0) {
            data.key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            data.key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }

        return "";
    }

    function _sqrtPriceFromAmounts(
        Currency currency0,
        Currency currency1,
        uint256 tokenAmount,
        uint256 ethAmount,
        address token
    ) internal pure returns (uint160) {
        uint256 amount0;
        uint256 amount1;
        if (currency0.isAddressZero()) {
            amount0 = ethAmount;
            amount1 = tokenAmount;
        } else if (Currency.unwrap(currency0) == token) {
            amount0 = tokenAmount;
            amount1 = ethAmount;
        }
        require(amount0 > 0 && amount1 > 0, "ZERO_AMOUNTS");
        // price = amount1/amount0 in token1/token0; sqrtPriceX96 = sqrt(amount1/amount0) * 2^96
        uint256 ratioX192 = (amount1 << 192) / amount0;
        uint256 sqrtRatio = _sqrt(ratioX192);
        return uint160(sqrtRatio);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    receive() external payable {}
}
