// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface ILayerZeroEndpoint {
    function send(uint16 _dstChainId, bytes calldata _destination, bytes calldata _payload,
        address payable _refundAddress, address _zroPaymentAddress, bytes calldata _adapterParams) external payable;
    function estimateFees(uint16 _dstChainId, address _userApplication, bytes calldata _payload,
        bool _payInZRO, bytes calldata _adapterParam) external view returns (uint256 nativeFee, uint256 zroFee);
}

contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    // --- Immutables ---
    IERC20 public immutable usdc;
    IERC20 public immutable token0;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable poolFee;
    ILayerZeroEndpoint public immutable lzEndpoint;

    // --- State ---
    uint256 public monthlyCap;
    uint256 public currentMonthWithdrawn;
    uint256 public currentMonthStart;
    bool public adminWithdrawEnabled;
    address public stakingRewardsAddress;

    // --- Keeper Bounty ---
    bool public keeperBountyEnabled;
    uint256 public keeperBountyAmount;
    mapping(address => bool) public authorizedRangeManagers;

    // --- Bridge (Phase 2) ---
    bool public bridgeEnabled;
    uint16 public bridgeDestinationChainId;
    address public bridgeDestinationAddress;

    // --- Events ---
    event AdminWithdrawal(uint256 amount, address indexed to);
    event AdminWithdrawDisabled(uint256 timestamp);
    event StakingRewardsSet(address indexed stakingRewards);
    event FeesDistributed(uint256 amount);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event SwappedToUSDC(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event BridgeConfigured(bool enabled, uint16 chainId, address destination);
    event BridgedToStakers(uint256 amount, uint16 destinationChainId);

    constructor(
        address _token0,
        address _usdc,
        address _swapRouter,
        uint24 _poolFee,
        uint256 _monthlyCap,
        bool _keeperBountyEnabled,
        uint256 _keeperBountyAmount,
        address _lzEndpoint
    ) {
        token0 = IERC20(_token0);
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter(_swapRouter);
        poolFee = _poolFee;
        monthlyCap = _monthlyCap;
        adminWithdrawEnabled = true;
        currentMonthStart = block.timestamp;
        keeperBountyEnabled = _keeperBountyEnabled;
        keeperBountyAmount = _keeperBountyAmount;
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);

        IERC20(_token0).safeApprove(_swapRouter, type(uint256).max);
    }

    receive() external payable {}

    // --- Public Functions ---

    /// @notice Swap token0 (ex: WETH) to USDC via Uniswap V3. Callable by anyone.
    function swapToUSDC(uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(amountIn > 0, "Zero amount");
        require(token0.balanceOf(address(this)) >= amountIn, "Insufficient balance");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(usdc),
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
        emit SwappedToUSDC(address(token0), amountIn, amountOut);
    }

    // --- Admin Functions (onlyOwner = Safe) ---

    function adminWithdraw(uint256 amount, address to) external onlyOwner {
        require(adminWithdrawEnabled, "Admin withdraw disabled");
        require(to != address(0), "Invalid recipient");

        if (block.timestamp >= currentMonthStart + 30 days) {
            currentMonthStart = block.timestamp;
            currentMonthWithdrawn = 0;
        }

        currentMonthWithdrawn += amount;
        require(currentMonthWithdrawn <= monthlyCap, "Monthly cap exceeded");

        usdc.safeTransfer(to, amount);
        emit AdminWithdrawal(amount, to);
    }

    function setMonthlyCap(uint256 newCap) external onlyOwner {
        emit MonthlyCapUpdated(monthlyCap, newCap);
        monthlyCap = newCap;
    }

    /// @notice Irreversibly disable admin withdrawals (Phase 2)
    function disableAdminWithdraw() external onlyOwner {
        adminWithdrawEnabled = false;
        emit AdminWithdrawDisabled(block.timestamp);
    }

    // --- Keeper Bounty Functions ---

    /// @notice Pay bounty to keeper who executed a rebalance. Called by authorized RangeManager.
    function payKeeperBounty(address keeper) external {
        require(authorizedRangeManagers[msg.sender], "Not authorized");
        require(keeperBountyEnabled, "Bounty disabled");
        require(keeperBountyAmount > 0, "Bounty is zero");
        require(usdc.balanceOf(address(this)) >= keeperBountyAmount, "Insufficient USDC");

        usdc.safeTransfer(keeper, keeperBountyAmount);
        emit KeeperBountyPaid(keeper, keeperBountyAmount);
    }

    function setKeeperBounty(bool _enabled, uint256 _amount) external onlyOwner {
        keeperBountyEnabled = _enabled;
        keeperBountyAmount = _amount;
        emit KeeperBountyConfigured(_enabled, _amount);
    }

    function authorizeRangeManager(address _rangeManager, bool _authorized) external onlyOwner {
        authorizedRangeManagers[_rangeManager] = _authorized;
    }

    // --- Phase 2 Prep (LayerZero bridge + staking) ---

    function setBridgeConfig(bool _enabled, uint16 _chainId, address _destination) external onlyOwner {
        bridgeEnabled = _enabled;
        bridgeDestinationChainId = _chainId;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _chainId, _destination);
    }

    /// @notice Bridge USDC to StakingRewards on destination chain via LayerZero. Callable by anyone.
    function bridgeToStakers(uint256 amount) external payable {
        require(bridgeEnabled, "Bridge disabled");
        require(bridgeDestinationAddress != address(0), "Destination not set");
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient USDC");

        bytes memory payload = abi.encode(bridgeDestinationAddress, amount);
        lzEndpoint.send{value: msg.value}(
            bridgeDestinationChainId,
            abi.encodePacked(bridgeDestinationAddress),
            payload,
            payable(msg.sender),
            address(0),
            bytes("")
        );

        emit BridgedToStakers(amount, bridgeDestinationChainId);
    }

    /// @notice Estimate LayerZero bridge fee
    function estimateBridgeFee(uint256 amount) external view returns (uint256 nativeFee, uint256 zroFee) {
        bytes memory payload = abi.encode(bridgeDestinationAddress, amount);
        return lzEndpoint.estimateFees(
            bridgeDestinationChainId,
            address(this),
            payload,
            false,
            bytes("")
        );
    }

    function setStakingRewards(address _stakingRewards) external onlyOwner {
        require(_stakingRewards != address(0), "Invalid address");
        stakingRewardsAddress = _stakingRewards;
        emit StakingRewardsSet(_stakingRewards);
    }

    function distributeToStakers(uint256 amount) external {
        require(stakingRewardsAddress != address(0), "Staking not configured");
        usdc.safeTransfer(stakingRewardsAddress, amount);
        emit FeesDistributed(amount);
    }
}
