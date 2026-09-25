// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "../src/hooks/PvPadHook.sol";
import {PvPadConstants} from "../src/libraries/PvPadConstants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Sepolia deploy (chainId 11155111). Requires PRIVATE_KEY and SEPOLIA_RPC_URL (or RPC_URL).
contract DeploySepolia is Script {
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envOr("POOL_MANAGER", PvPadConstants.SEPOLIA_POOL_MANAGER);

        vm.startBroadcast(deployerKey);

        WorkerSubsidy subsidy = new WorkerSubsidy();
        KingOfThePad king = new KingOfThePad(subsidy);
        FeeEscrow escrow = new FeeEscrow(king);
        PvPadFactory factory = new PvPadFactory(IPoolManager(poolManager), subsidy, king, escrow);

        bytes memory ctor = abi.encode(IPoolManager(poolManager), IPvPadLaunchRegistry(address(factory)), escrow);
        address hookDeployer = vm.addr(deployerKey);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(hookDeployer, HOOK_FLAGS, type(PvPadHook).creationCode, ctor);

        console2.log("Expected hook (CREATE2 via canonical deployer):", hookAddr);
        console2.log("Salt:", vm.toString(salt));

        PvPadHook hook = new PvPadHook{salt: salt}(
            IPoolManager(poolManager), IPvPadLaunchRegistry(address(factory)), escrow
        );
        require(address(hook) == hookAddr, "HOOK_ADDR_MISMATCH");

        factory.setHook(hook);
        factory.bootstrapGenesis();

        vm.stopBroadcast();

        console2.log("WorkerSubsidy", address(subsidy));
        console2.log("KingOfThePad", address(king));
        console2.log("FeeEscrow", address(escrow));
        console2.log("PvPadFactory", address(factory));
        console2.log("PvPadHook", address(hook));
        console2.log("PoolManager", poolManager);
        console2.log("Updater", PvPadConstants.INITIAL_UPDATER);
    }
}
