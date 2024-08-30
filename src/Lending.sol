// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract DreamAcademyLending {
    IPriceOracle public oracle;
    ERC20 public usdc;

    uint256 public totalReserves;
    uint256 public totalDebt;
    uint256 public reserveFactor = 5 * 10 ** 16;
    uint256 public borrowIndex = 1e18;
    uint256 public constant SECONDS_PER_BLOCK = 12;
    uint256 public constant INTEREST_RATE_PER_BLOCK = 1e15;

    struct UserInfo {
        uint256 supplied;
        uint256 borrowed;
        uint256 lastBorrowIndex;
        uint256 lastBlockNumber;
    }

    mapping(address => UserInfo) public users;

    constructor(IPriceOracle _oracle, address _usdc) {
        oracle = _oracle;
        usdc = ERC20(_usdc);
    }

    function initializeLendingProtocol(address asset) external payable {
        if (asset == address(0)) {
            require(msg.value > 0, "Initial reserve must be positive");
            totalReserves += msg.value;
        } else if (asset == address(usdc)) {
            uint256 usdcAmount = 1; 
            require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        } else {
            revert("Unsupported asset");
        }
    }

    function deposit(address asset, uint256 amount) external payable {
        if (asset == address(0)) {
            require(msg.value == amount, "Ether deposit value mismatch");
            users[msg.sender].supplied += msg.value;
        } else if (asset == address(usdc)) {
            require(usdc.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
            users[msg.sender].supplied += amount;
            uint256 contractBalance = usdc.balanceOf(address(this));
            require(contractBalance >= amount, "Contract balance mismatch after deposit");
        } else {
            revert("Unsupported asset");
        }
    }

    function borrow(address asset, uint256 amount) external {
        require(asset == address(usdc), "Only USDC borrowing supported");
        updateBorrowIndex();
        accrueInterest(msg.sender);
        uint256 collateralValue = users[msg.sender].supplied * oracle.getPrice(address(0)) / 1e18;
        uint256 borrowable = (collateralValue * 75) / 100;
        require(users[msg.sender].borrowed + amount <= borrowable, "Insufficient collateral");
        users[msg.sender].borrowed += amount;
        totalDebt += amount;
        users[msg.sender].lastBlockNumber = block.number;
        require(usdc.transfer(msg.sender, amount), "USDC transfer failed");
    }

    function repay(address asset, uint256 amount) external {
        require(asset == address(usdc), "Only USDC repayment supported");
        updateBorrowIndex();
        accrueInterest(msg.sender);
        require(users[msg.sender].borrowed >= amount, "Exceeds borrowed amount");
        require(usdc.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        users[msg.sender].borrowed -= amount;
        totalDebt -= amount;
    }

    function withdraw(address asset, uint256 amount) external {
        require(asset == address(0) || asset == address(usdc), "Unsupported asset");
        updateBorrowIndex();
        accrueInterest(msg.sender);
        if (asset == address(0)) {
            uint256 withdrawable = users[msg.sender].supplied - (users[msg.sender].borrowed * oracle.getPrice(address(usdc)) / oracle.getPrice(address(0)));
            require(withdrawable >= amount, "Insufficient collateral to withdraw");
            users[msg.sender].supplied -= amount;
            payable(msg.sender).transfer(amount);
        } else if (asset == address(usdc)) {
            uint256 usdcBalance = usdc.balanceOf(address(this));
            require(usdcBalance >= amount, "Insufficient contract USDC balance");
            require(usdc.transfer(msg.sender, amount), "USDC transfer failed");
        }
    }

    function liquidate(address borrower, address asset, uint256 amount) external {
        require(asset == address(usdc), "Only USDC liquidation supported");
        updateBorrowIndex();
        accrueInterest(borrower);
        uint256 debtValue = users[borrower].borrowed;
        uint256 collateralValue = users[borrower].supplied * oracle.getPrice(address(0)) / 1e18;
        require(debtValue > (collateralValue * 75) / 100, "Loan is not unhealthy");
        require(amount <= debtValue * 25 / 100, "Liquidation exceeds allowed amount");
        require(usdc.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        users[borrower].borrowed -= amount;
        totalDebt -= amount;
        uint256 seizedCollateral = amount * 1e18 / oracle.getPrice(address(0));
        users[borrower].supplied -= seizedCollateral;
        payable(msg.sender).transfer(seizedCollateral);
    }

    function getAccruedSupplyAmount(address asset) external view returns (uint256) {
        require(asset == address(usdc), "Only USDC accrual supported");
        return usdc.balanceOf(address(this)) - totalDebt - totalReserves;
    }

    function updateBorrowIndex() internal {
        uint256 blocksElapsed = block.number - users[msg.sender].lastBlockNumber;
        borrowIndex += INTEREST_RATE_PER_BLOCK * blocksElapsed;
    }

    function accrueInterest(address user) internal {
        UserInfo storage userInfo = users[user];
        uint256 interest = userInfo.borrowed * (borrowIndex - userInfo.lastBorrowIndex) / 1e18;
        userInfo.borrowed += interest;
        totalDebt += interest;
        userInfo.lastBorrowIndex = borrowIndex;
    }

    receive() external payable {
        totalReserves += msg.value;
    }
}
