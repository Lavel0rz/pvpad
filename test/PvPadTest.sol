// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "../src/hooks/PvPadHook.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadConstants} from "../src/libraries/PvPadConstants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
contract PvPadTest is Test {

    PoolManager manager;
    PoolSwapTest swapRouter;
    WorkerSubsidy subsidy;
    KingOfThePad king;
    FeeEscrow escrow;
    PvPadFactory factory;
    PvPadHook hook;

    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address kingBidder = makeAddr("kingBidder");
    address worker = makeAddr("worker");

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(manager));
        subsidy = new WorkerSubsidy();
        king = new KingOfThePad(subsidy);
        escrow = new FeeEscrow(king);
        factory = new PvPadFactory(IPoolManager(manager), subsidy, king, escrow);
        hook = _deployHook();
        factory.setHook(hook);
    }

    function _deployHook() internal returns (PvPadHook) {
        bytes memory ctor = abi.encode(IPoolManager(manager), IPvPadLaunchRegistry(address(factory)), escrow);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PvPadHook).creationCode, ctor);
        PvPadHook h =
            new PvPadHook{salt: salt}(IPoolManager(manager), IPvPadLaunchRegistry(address(factory)), escrow);
        assertEq(address(h), expected, "hook addr");
        return h;
    }

    function test_genesisZeroFee() public {
        uint256 potBefore = subsidy.workerPot();
        uint256 id = factory.bootstrapGenesis();
        assertEq(id, 0);
        assertEq(factory.launchCount(), 1);
        assertEq(subsidy.workerPot(), potBefore);

        (, address c,) = _launch(0);
        BondingCurve curve = BondingCurve(payable(c));
        assertEq(curve.token().balanceOf(address(curve)), PvPadConstants.TOKEN_SUPPLY);
    }

    function test_paidCreateFundsWorkers() public {
        factory.bootstrapGenesis();
        uint256 pot = subsidy.workerPot();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        factory.createLaunch{value: PvPadConstants.DEFAULT_LAUNCH_FEE}("Alpha", "ALP");
        assertEq(subsidy.workerPot(), pot + PvPadConstants.DEFAULT_LAUNCH_FEE);
        assertEq(factory.launchCount(), 2);
    }

    function test_curveBuyFeesSplitKingAndCreator() public {
        factory.bootstrapGenesis();
        vm.deal(trader, 10 ether);
        vm.deal(kingBidder, 1 ether);
        (, address curveAddr,) = _launch(0);
        BondingCurve curve = BondingCurve(payable(curveAddr));

        vm.prank(kingBidder);
        king.claimKing{value: 0.02 ether}(kingBidder);

        vm.prank(trader);
        curve.buy{value: 1 ether}(trader);

        uint256 fee = (1 ether * PvPadConstants.FEE_BPS) / PvPadConstants.BPS_DENOMINATOR;
        uint256 half = fee / 2;
        assertEq(escrow.pending(address(0), kingBidder), half);
        assertEq(escrow.pending(address(0), address(this)), half); // genesis creator = test contract
    }

    function test_multiLaunchFeesHitSameKing() public {
        factory.bootstrapGenesis();
        vm.deal(creator, 2 ether);
        vm.prank(creator);
        factory.createLaunch{value: PvPadConstants.DEFAULT_LAUNCH_FEE}("B", "BB");

        vm.deal(kingBidder, 1 ether);
        vm.prank(kingBidder);
        king.claimKing{value: 0.02 ether}(kingBidder);

        (, address curve0,) = _launch(0);
        (, address curve1,) = _launch(1);

        vm.deal(trader, 10 ether);
        vm.prank(trader);
        BondingCurve(payable(curve0)).buy{value: 0.5 ether}(trader);
        vm.prank(trader);
        BondingCurve(payable(curve1)).buy{value: 0.5 ether}(trader);

        uint256 kingPending = escrow.pending(address(0), kingBidder);
        assertGt(kingPending, 0);
        assertEq(
            kingPending,
            escrow.pending(address(0), kingBidder)
        );
    }

    function test_graduateStopsCurveAndRegistersPool() public {
        factory.bootstrapGenesis();
        (, address curveAddr, address tokenAddr) = _launch(0);
        BondingCurve curve = BondingCurve(payable(curveAddr));

        _fillToGraduation(curve);

        PoolId poolId = factory.graduate(0);
        assertTrue(factory.registeredPool(poolId));
        vm.expectRevert(BondingCurve.Graduated.selector);
        vm.prank(trader);
        curve.buy{value: 1 ether}(trader);
    }

    function test_kingClaimFundsPot() public {
        uint256 pot = subsidy.workerPot();
        vm.deal(kingBidder, 1 ether);
        vm.prank(kingBidder);
        king.claimKing{value: 0.05 ether}(kingBidder);
        assertEq(subsidy.workerPot(), pot + 0.05 ether);
        assertGt(king.claimPrice(), PvPadConstants.INITIAL_CLAIM_PRICE);
    }

    function test_workerMerkleClaim() public {
        vm.deal(kingBidder, 1 ether);
        vm.prank(kingBidder);
        king.claimKing{value: 0.1 ether}(kingBidder);

        bytes32 root = subsidy.leaf(1, worker, 0.05 ether);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(PvPadConstants.INITIAL_UPDATER);
        subsidy.setEpoch(root, block.timestamp, block.timestamp + 7 days);

        uint256 balBefore = worker.balance;
        subsidy.claimWorker(1, worker, 0.05 ether, proof);
        assertEq(worker.balance, balBefore + 0.05 ether);
    }

    function _fillToGraduation(BondingCurve curve) internal {
        vm.deal(trader, 50 ether);
        while (!curve.readyToGraduate()) {
            vm.prank(trader);
            curve.buy{value: 0.5 ether}(trader);
        }
    }

    function _launch(uint256 id) internal view returns (address token, address curve, address creatorAddr) {
        (creatorAddr, token, curve,,) = factory.launches(id);
    }

}
