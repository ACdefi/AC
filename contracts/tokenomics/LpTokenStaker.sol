// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BaseMinter.sol";
import "../../interfaces/tokenomics/ILpTokenStaker.sol";
import "../../interfaces/tokenomics/IInflationManager.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/pools/IAcPool.sol";
import "../../interfaces/pools/ILpToken.sol";
import "../../interfaces/tokenomics/ICNCToken.sol";
import "../../libraries/ScaledMath.sol";

/// @dev USD amounts in this contract are always scaled by 1e18
contract LpTokenStaker is ILpTokenStaker, BaseMinter {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILpToken;
    using ScaledMath for uint256;
    struct Boost {
        uint256 timeBoost;
        uint256 lastUpdated;
    }

    uint256 public constant MAX_BOOST = 10e18;
    uint256 public constant MIN_BOOST = 1e18;
    uint256 public constant TIME_STARTING_FACTOR = 1e17;
    uint256 public constant INCREASE_PERIOD = 30 days;
    uint256 public constant TVL_FACTOR = 50e18;

    mapping(address => mapping(address => uint256)) internal stakedPerUser;
    mapping(address => uint256) internal _stakedPerPool;
    mapping(address => Boost) public boosts;

    mapping(address => uint256) public poolShares;
    mapping(address => uint256) public poolLastUpdated;

    IController public immutable controller;

    bool public isShutdown;

    modifier notShutdown() {
        require(!isShutdown, "LpTokenStaker: shutdown");
        _;
    }

    constructor(
        address controller_,
        ICNCToken _cnc,
        address _emergencyMinter
    ) BaseMinter(_cnc, _emergencyMinter) {
        controller = IController(controller_);
        _initializeLastUpdated();
    }

    function stake(uint256 amount, address acPool) external override {
        stakeFor(amount, acPool, msg.sender);
    }

    function unstake(uint256 amount, address acPool) external override {
        unstakeFor(amount, acPool, msg.sender);
    }

    function stakeFor(
        uint256 amount,
        address acPool,
        address account
    ) public override notShutdown {
        require(controller.isPool(acPool), "not a ac pool");
        ILpToken lpToken = IAcPool(acPool).lpToken();
        uint256 exchangeRate = IAcPool(acPool).usdExchangeRate();
        // Checkpoint all inflation logic
        IAcPool(acPool).rewardManager().accountCheckpoint(account);
        _stakerCheckpoint(
            account,
            amount.convertScale(lpToken.decimals(), 18).mulDown(exchangeRate)
        );
        // Actual staking
        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        stakedPerUser[account][acPool] += amount;
        _stakedPerPool[acPool] += amount;
    }

    function unstakeFor(
        uint256 amount,
        address acPool,
        address account
    ) public override {
        require(controller.isPool(acPool), "not a ac pool");
        require(stakedPerUser[msg.sender][acPool] >= amount, "not enough staked");
        // Checkpoint all inflation logic
        if (!isShutdown) {
            IAcPool(acPool).rewardManager().accountCheckpoint(msg.sender);
            _stakerCheckpoint(msg.sender, 0);
        }
        // Actual unstaking
        stakedPerUser[msg.sender][acPool] -= amount;
        _stakedPerPool[acPool] -= amount;
        IAcPool(acPool).lpToken().safeTransfer(account, amount);
    }

    function unstakeFrom(uint256 amount, address account) public override {
        require(controller.isPool(msg.sender), "only callable from ac pool");
        require(stakedPerUser[account][msg.sender] >= amount, "not enough staked");
        // Checkpoint all inflation logic
        IAcPool(msg.sender).rewardManager().accountCheckpoint(account);
        _stakerCheckpoint(account, 0);
        // Actual unstaking
        stakedPerUser[account][msg.sender] -= amount;
        _stakedPerPool[msg.sender] -= amount;
        IAcPool(msg.sender).lpToken().safeTransfer(account, amount);
    }

    function shutdown() external {
        require(msg.sender == emergencyMinter, "LpTokenStaker: not emergency minter");
        address[] memory pools = controller.listPools();
        for (uint256 i; i < pools.length; i++) {
            _claimCNCRewardsForPool(pools[i]);
        }
        isShutdown = true;
        emit Shutdown();
    }

    function getUserBalanceForPool(address acPool, address account)
        external
        view
        override
        returns (uint256)
    {
        return stakedPerUser[account][acPool];
    }

    function getBalanceForPool(address acPool) external view override returns (uint256) {
        return _stakedPerPool[acPool];
    }

    function getCachedBoost(address user) external view returns (uint256) {
        return boosts[user].timeBoost;
    }

    function getTimeToFullBoost(address user) external view returns (uint256) {
        uint256 fullBoostAt_ = boosts[user].lastUpdated + INCREASE_PERIOD;
        if (fullBoostAt_ <= block.timestamp) return 0;
        return fullBoostAt_ - block.timestamp;
    }

    function getBoost(address user) external view override returns (uint256) {
        if (isShutdown) return MIN_BOOST;
        (uint256 userStakedUSD, uint256 totalStakedUSD) = _getTotalStakedForUserCommonDenomination(
            user
        );
        if (totalStakedUSD == 0 || userStakedUSD == 0) {
            return MIN_BOOST;
        }
        uint256 stakeBoost = ScaledMath.ONE +
            userStakedUSD.divDown(totalStakedUSD).mulDown(TVL_FACTOR);

        Boost storage userBoost = boosts[user];
        uint256 timeBoost = userBoost.timeBoost;
        timeBoost += (block.timestamp - userBoost.lastUpdated).divDown(INCREASE_PERIOD).mulDown(
            ScaledMath.ONE - TIME_STARTING_FACTOR
        );
        if (timeBoost > ScaledMath.ONE) {
            timeBoost = ScaledMath.ONE;
        }
        uint256 totalBoost = stakeBoost.mulDown(timeBoost);
        if (totalBoost < MIN_BOOST) {
            totalBoost = MIN_BOOST;
        } else if (totalBoost > MAX_BOOST) {
            totalBoost = MAX_BOOST;
        }
        return totalBoost;
    }

    function updateBoost(address user) external override notShutdown {
        (uint256 userStaked, ) = _getTotalStakedForUserCommonDenomination(user);
        _updateTimeBoost(user, userStaked, 0);
    }

    function claimCNCRewardsForPool(address pool) external override notShutdown {
        require(
            msg.sender == address(IAcPool(pool).rewardManager()),
            "can only be called by reward manager"
        );
        _claimCNCRewardsForPool(pool);
    }

    function _claimCNCRewardsForPool(address pool) internal {
        require(controller.isPool(pool), "not a pool");
        checkpoint(pool);
        uint256 cncToMint = poolShares[pool];
        if (cncToMint == 0) {
            return;
        }
        cnc.mint(address(pool), cncToMint);
        controller.inflationManager().executeInflationRateUpdate();
        poolShares[pool] = 0;
        emit TokensClaimed(pool, cncToMint);
    }

    function claimableCnc(address pool) public view override returns (uint256) {
        if (isShutdown) return 0;
        uint256 currentRate = controller.inflationManager().getCurrentPoolInflationRate(pool);
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        return poolShares[pool] + (currentRate * timeElapsed);
    }

    function _stakerCheckpoint(address account, uint256 amountAddedUSD) internal {
        (uint256 userStakedUSD, ) = _getTotalStakedForUserCommonDenomination(account);
        _updateTimeBoost(account, userStakedUSD, amountAddedUSD);
    }

    function checkpoint(address pool) public override notShutdown returns (uint256) {
        // Update the integral of total token supply for the pool
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        if (timeElapsed == 0) return poolShares[pool];
        poolCheckpoint(pool);
        poolLastUpdated[pool] = block.timestamp;
        return poolShares[pool];
    }

    function poolCheckpoint(address pool) internal {
        uint256 currentRate = controller.inflationManager().getCurrentPoolInflationRate(pool);
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        poolShares[pool] += (currentRate * timeElapsed);
    }

    function _updateTimeBoost(
        address user,
        uint256 userStakedUSD,
        uint256 amountAddedUSD
    ) internal {
        Boost storage userBoost = boosts[user];

        if (userStakedUSD == 0) {
            userBoost.timeBoost = TIME_STARTING_FACTOR;
            userBoost.lastUpdated = block.timestamp;
            return;
        }
        uint256 newBoost;
        newBoost = userBoost.timeBoost;
        newBoost += (block.timestamp - userBoost.lastUpdated).divDown(INCREASE_PERIOD).mulDown(
            ScaledMath.ONE - TIME_STARTING_FACTOR
        );
        if (newBoost > ScaledMath.ONE) {
            newBoost = ScaledMath.ONE;
        }
        if (amountAddedUSD == 0) {
            userBoost.timeBoost = newBoost;
        } else {
            uint256 newTotalStakedUSD = userStakedUSD + amountAddedUSD;
            userBoost.timeBoost =
                newBoost.mulDown(userStakedUSD.divDown(newTotalStakedUSD)) +
                TIME_STARTING_FACTOR.mulDown(amountAddedUSD.divDown(newTotalStakedUSD));
        }
        userBoost.lastUpdated = block.timestamp;
    }

    function _getUserUSDStakedInPool(address account, address pool)
        internal
        view
        returns (uint256 poolStaked, uint256 poolUserStaked)
    {
        uint256 curExchangeRate = IAcPool(pool).usdExchangeRate();

        uint8 decimals = IAcPool(pool).lpToken().decimals();
        poolStaked = _stakedPerPool[pool].convertScale(decimals, 18).mulDown(curExchangeRate);
        poolUserStaked = stakedPerUser[account][pool].convertScale(decimals, 18).mulDown(
            curExchangeRate
        );
    }

    function _getTotalStakedForUserCommonDenomination(address account)
        public
        view
        returns (uint256, uint256)
    {
        address[] memory acPools = controller.listPools();
        uint256 totalStakedUSD = 0;
        uint256 userStakedUSD = 0;
        for (uint256 i; i < acPools.length; i++) {
            (uint256 poolStakedUSD, uint256 poolUserStakedUSD) = _getUserUSDStakedInPool(
                account,
                acPools[i]
            );
            totalStakedUSD += poolStakedUSD;
            userStakedUSD += poolUserStakedUSD;
        }
        return (userStakedUSD, totalStakedUSD);
    }

    function _initializeLastUpdated() internal {
        address[] memory pools = controller.listPools();
        for (uint256 i; i < pools.length; i++) {
            poolLastUpdated[pools[i]] = block.timestamp;
        }
    }
}
