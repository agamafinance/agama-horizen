// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HonkVerifier} from "../src/HonkVerifier.sol";
import {DeltaVerifier} from "../src/DeltaVerifier.sol";
import {CreditDisclosureRegistry} from "../src/CreditDisclosureRegistry.sol";
import {AgamaCreditVault} from "../src/AgamaCreditVault.sol";

/// Deploy the disclosure stack to Horizen.
///
///   forge script script/Deploy.s.sol --rpc-url $HORIZEN_RPC --broadcast --private-key $PK
///
/// Testnet needs ETH from https://hub-testnet.horizen.io (browser session).
contract Deploy is Script {
    // Horizen mainnet (26514) USDC.e. Override with ASSET for testnet.
    address constant USDCE_MAINNET = 0xDF7108f8B10F9b9eC1aba01CCa057268cbf86B6c;
    address constant PUREFI_MAINNET = 0x681Edd4906e2a0a277E2A6c394A4595f83e1329c;

    function run() external {
        address asset = vm.envOr("ASSET", USDCE_MAINNET);
        address admin = vm.envOr("ADMIN", msg.sender);
        uint64 genesis = uint64(vm.envOr("GENESIS", block.timestamp));

        vm.startBroadcast();

        HonkVerifier verifier = new HonkVerifier();
        DeltaVerifier deltaVerifier = new DeltaVerifier();
        CreditDisclosureRegistry registry = new CreditDisclosureRegistry(
            address(verifier), address(deltaVerifier), asset, admin, genesis
        );
        AgamaCreditVault vault = new AgamaCreditVault(IERC20(asset), registry, admin);

        registry.setVault(address(vault));
        if (block.chainid == 26514) vault.setCompliance(PUREFI_MAINNET);

        vm.stopBroadcast();

        console.log("chainId          ", block.chainid);
        console.log("HonkVerifier     ", address(verifier));
        console.log("DeltaVerifier    ", address(deltaVerifier));
        console.log("Registry         ", address(registry));
        console.log("Vault            ", address(vault));
        console.log("asset            ", asset);
        console.log("epoch genesis    ", genesis);
    }
}
