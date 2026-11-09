// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockUSDC —— 仅用于测试，不要上主网
/// @notice 刻意做成和真实 USDC 一样的三个特征：
///         1. decimals = 6（不是 18）
///         2. 有黑名单（真实 USDC 可以冻结任意地址）
///         3. 有可增发的 minter（真实 USDC 由发行方按储备增发）
/// @dev 这三点决定了「稳定币不是无许可资产」。做 RWA 方案时，它们就是合规侧的抓手，
///      同时也是你必须向业务方写进合同的风险条款：发行方可以冻你的收款地址。
contract MockUSDC {
    string public name = "Mock USD Coin";
    string public symbol = "mUSDC";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice 发行方（真实世界里是 Circle）
    address public immutable masterMinter;

    /// @notice 被冻结的地址：不能转出、不能转入。真实 USDC 就是这么干的。
    mapping(address => bool) public isBlacklisted;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event BlacklistUpdated(address indexed account, bool blocked);

    error Blacklisted(address account);
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);
    error NotMinter();
    error ZeroAddress();

    constructor() {
        masterMinter = msg.sender;
    }

    /* ---------------- 发行方权限 ---------------- */

    /// @notice 增发。真实世界每一次增发背后都对应一笔储备金入账 —— 这就是「储备证明」要证明的东西
    function mint(address to, uint256 value) external {
        if (msg.sender != masterMinter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    /// @notice 冻结 / 解冻。这一段是「合规」在代码里的具体形态
    function setBlacklist(address account, bool blocked) external {
        if (msg.sender != masterMinter) revert NotMinter();
        isBlacklisted[account] = blocked;
        emit BlacklistUpdated(account, blocked);
    }

    /* ---------------- ERC-20 ---------------- */

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        // type(uint256).max 视为无限授权，不扣减 —— 省一次 SSTORE，也是行业惯例
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(allowed, value);
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        if (isBlacklisted[from]) revert Blacklisted(from);
        if (isBlacklisted[to]) revert Blacklisted(to);
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance(bal, value);
        unchecked {
            balanceOf[from] = bal - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
