// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IPancakeRouterVault.sol";
import "./IOXFIERC20.sol";


/*

     ____   __   __  ______   _____ 
    / __ \  \ \ / / |  ____| |_   _|
   | |  | |  \ V /  | |__      | |  
   | |  | |   > <   |  __|     | |  
   | |__| |  / . \  | |       _| |_ 
    \____/  /_/ \_\ |_|      |_____|

   Website: https://oxfi.app/
   Telegram: https://t.me/OXFIcommunity
   Build by: KISHIELD.com                
   Contract: OXFIvault.sol

   STATE: PRODUCTION
*/

contract OXFIvault is ReentrancyGuard {

    address public owner;
    uint256 public totalOxfiDeposited;
    uint256 public totalBusdRedeemed;

    // Lock variables
    uint256 private immutable creationTime;
    uint256 private lockTime = 30 days;

    // ERC20s
    IOXFIERC20 immutable OXFI;
	IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

	event OxfiDeposited(address indexed user, uint256 indexed deposited);
	event BusdRedeemed(address indexed user, uint256 indexed deposited);
	event TransferOwnership(address indexed numberExtraDays);
	event RenounceOwnership(address indexed newOwner);
	event OwnerWithdraw(bytes32 indexed busdAmount);
	event IncreaseLockTime(uint256 indexed amount);


    constructor(address _token, address _router, address _owner) {
        OXFI = IOXFIERC20(_token);
        BUSD.approve(address(this), type(uint256).max);
        BUSD.approve(address(_router), type(uint256).max);
        owner = _owner;
        creationTime = block.timestamp;
    }

    function balanceBUSD() public view returns (uint256) {
        return BUSD.balanceOf(address(this));
    }

    function userBalanceBUSD(address user) public view returns (uint256) {
        return BUSD.balanceOf(user);
    }

    function oxfiSupply() public view returns (uint256) {
        return OXFI.totalSupply();
    }

    function rate(uint256 amount) public view returns (uint256) {
        return (amount * balanceBUSD()) / oxfiSupply();
    }

    function userOxfiBalance(address user) public view returns (uint256) {
        return OXFI.balanceOf(user);
    }

    function redeemBUSD(uint256 amount) external nonReentrant {
        require(userOxfiBalance(msg.sender) >= amount, "OXFIvault: Not enough OXFI");

        require(OXFI.destroy(msg.sender, amount), "OXFIvault: Tokens not destroyed");

        uint busdForTransfer = rate(amount);

        require(balanceBUSD() >= busdForTransfer, "OXFIvault: Not enough BUSD in vault");
        BUSD.transferFrom(address(this), msg.sender, busdForTransfer);

        totalOxfiDeposited += amount;
        totalBusdRedeemed += busdForTransfer;

        emit OxfiDeposited(msg.sender, amount);
        emit BusdRedeemed(msg.sender, busdForTransfer);
    }

    function previewRedeemBUSD(uint256 amount) external view returns(uint256) {
        uint busdForTransfer = rate(amount);
        return busdForTransfer;
    }

    function transferOwnership(address _newOwner) external {
        require(msg.sender == owner, "OFXI: You are not the owner");
        require(_newOwner != address(0), "OFXI: Ownership cannot be transfered to the zero address");
        owner = _newOwner;
        emit TransferOwnership(_newOwner);
    } 

    function renounceOwnership() external {
        require(msg.sender == owner, "OFXI: You are not the owner");
        owner = address(0);
        emit RenounceOwnership(address(0));
    } 

    function withdrawBUSD() external {
        require(msg.sender == owner, "OFXI: You are not the owner");
        require(block.timestamp > creationTime + lockTime, "OXFI: lock time not over");
        BUSD.transferFrom(address(this), msg.sender, BUSD.balanceOf(address(this)));
        emit OwnerWithdraw("ALL BUSD");

    }

    function increaseLockTime(uint8 numberExtraDays) external {
        require(msg.sender == owner, "OFXI: You are not the owner");
        lockTime = lockTime + (numberExtraDays * 86400);
        emit IncreaseLockTime(numberExtraDays);
    }

}