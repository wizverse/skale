// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Mock is ERC20Burnable, Ownable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, 100000 * 10**6);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function mintTokens(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
} 