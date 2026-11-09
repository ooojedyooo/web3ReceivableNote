// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC20 最小接口
/// @notice ERC-20 的全部「必需」部分只有 6 个函数 + 2 个事件。
///         其余（name/symbol/decimals）在标准里是「可选」的 —— 但实务中你必须读 decimals。
/// @dev 注意：这个接口里的 transferFrom 声明了 returns (bool)，
///      而 USDT 这类老代币的实现「不返回值」。按接口直接调用会解码失败 —— 见 ReceivableNoteUSD 的 _pullExact。
interface IERC20 {
    /* ---------------- 必需：6 个函数 ---------------- */

    /// @notice 总量。注意它可以是通胀的（增发）或通缩的（销毁），不是常量
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    /// @notice 直接转账：从 msg.sender 转到 to
    function transfer(address to, uint256 value) external returns (bool);

    /// @notice 授权：允许 spender 最多从你的账户拉走 value
    /// @dev 这是 ERC-20 最容易被误用、也最容易被钓鱼滥用的函数
    function approve(address spender, uint256 value) external returns (bool);

    /// @notice 拉款：把 from 的余额转给 to，消耗 from 给 msg.sender 的授权额度
    /// @dev 关键点：只有 from 事先 approve 过 msg.sender，这一句才可能成功
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    /// @notice 剩余授权额度。对账系统要监控这个值 —— 它等于「这个合约最多还能从该用户拿走多少钱」
    function allowance(address owner, address spender) external view returns (uint256);

    /* ---------------- 必需：2 个事件 ---------------- */

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /* ---------------- 可选：实务中必读 ---------------- */

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    /// @notice 小数位。USDC/USDT = 6，DAI = 18，WBTC = 8
    /// @dev 链上没有 float，金额永远是整数。所谓「1.5 USDC」在链上就是 1500000。
    ///      单位搞错 10^12 倍，是这个行业最经典的资金事故。
    function decimals() external view returns (uint8);
}
