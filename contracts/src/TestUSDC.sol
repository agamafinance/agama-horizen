// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for USDC.e on Horizen testnet, where no canonical
///         stablecoin is deployed. Mainnet uses the real USDC.e at
///         0xDF7108f8B10F9b9eC1aba01CCa057268cbf86B6c.
contract TestUSDC is ERC20 {
    constructor() ERC20("Agama Test USDC", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
