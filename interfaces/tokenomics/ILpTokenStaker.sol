// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

interface ILpTokenStaker {
    event LpTokenStaked(address indexed account, uint256 amount);
    event LpTokenUnstaked(address indexed account, uint256 amount);
    event TokensClaimed(address indexed pool, uint256 cncAmount);
    event Shutdown();

    function stake(uint256 amount, address acPool) external;

    function unstake(uint256 amount, address acPool) external;

    function stakeFor(
        uint256 amount,
        address acPool,
        address account
    ) external;

    function unstakeFor(
        uint256 amount,
        address acPool,
        address account
    ) external;

    function unstakeFrom(uint256 amount, address account) external;

    function getUserBalanceForPool(address acPool, address account)
        external
        view
        returns (uint256);

    function getBalanceForPool(address acPool) external view returns (uint256);

    function updateBoost(address user) external;

    function claimCNCRewardsForPool(address pool) external;

    function claimableCnc(address pool) external view returns (uint256);

    function checkpoint(address pool) external returns (uint256);

    function shutdown() external;

    function getBoost(address user) external view returns (uint256);
}
