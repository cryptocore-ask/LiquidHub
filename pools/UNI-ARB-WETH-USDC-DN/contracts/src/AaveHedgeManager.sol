// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IAaveV3Pool.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";

/// @title AaveHedgeManager - AAVE V3 hedge for Delta Neutral strategy (75/25)
/// @notice Manages supply/borrow/repay/withdraw on AAVE V3 for the DN pool hedge.
///         Supports atomic settlement via flash loan for user withdrawals.
/// @dev All write functions are restricted to the Gnosis Safe via onlySafe modifier,
///      except settleProportional which is called by the vault during atomic withdraw.
contract AaveHedgeManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== IMMUTABLES =====
    address public immutable safe;
    address public immutable vault;
    IAaveV3Pool public immutable pool;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 public immutable variableDebtWeth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapPoolFee;

    // ===== STATE =====
    bool public paused;
    bool private _flashLoanActive;

    // ===== EVENTS =====
    event SupplyAndBorrow(uint256 usdcSupplied, uint256 wethBorrowed);
    event BorrowMore(uint256 wethBorrowed);
    event RepayAndWithdraw(uint256 wethRepaid, uint256 usdcWithdrawn);
    event RepayDebt(uint256 wethRepaid);
    event WithdrawCollateral(uint256 usdcWithdrawn, address to);
    event CloseAll(address recipient, uint256 usdcSent);
    event EmergencyClose(address recipient, uint256 usdcSent);
    event SweepWeth(address to, uint256 amount);
    event SweepUsdc(address to, uint256 amount);
    event Paused(bool paused);
    event SettleProportional(uint256 wethUsed, uint256 proportionBps, address recipient, uint256 usdcRecovered);

    // ===== MODIFIERS =====
    modifier onlySafe() {
        require(msg.sender == safe, "Only Safe");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only Vault");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ===== CONSTRUCTOR =====
    /// @param _safe Gnosis Safe address (sole authorized caller for admin functions)
    /// @param _vault MultiUserVault address (authorized caller for settleProportional)
    /// @param _pool AAVE V3 Pool on Arbitrum (0x794a61358D6845594F94dc1DB02A252b5b4814aD)
    /// @param _usdc USDC on Arbitrum (0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
    /// @param _weth WETH on Arbitrum (0x82aF49447D8a07e3bd95BD0d56f35241523fBab1)
    /// @param _variableDebtWeth AAVE V3 variable debt WETH token on Arbitrum
    /// @param _swapRouter Uniswap V3 SwapRouter address (0xE592427A0AEce92De3Edee1F18E0157C05861564 on Arbitrum)
    /// @param _swapPoolFee Uniswap V3 pool fee tier for token0/token1 pair (500 = 0.05%, 3000 = 0.30%)
    constructor(
        address _safe,
        address _vault,
        address _pool,
        address _usdc,
        address _weth,
        address _variableDebtWeth,
        address _swapRouter,
        uint24 _swapPoolFee
    ) {
        require(_safe != address(0), "Invalid safe");
        require(_vault != address(0), "Invalid vault");
        require(_pool != address(0), "Invalid pool");
        require(_usdc != address(0), "Invalid usdc");
        require(_weth != address(0), "Invalid weth");
        require(_variableDebtWeth != address(0), "Invalid vDebtWeth");
        require(_swapRouter != address(0), "Invalid swapRouter");
        require(_swapPoolFee > 0, "Invalid swapPoolFee");

        safe = _safe;
        vault = _vault;
        pool = IAaveV3Pool(_pool);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        variableDebtWeth = IERC20(_variableDebtWeth);
        swapRouter = ISwapRouter(_swapRouter);
        swapPoolFee = _swapPoolFee;

        // Approve max USDC and WETH to AAVE Pool for supply/repay
        IERC20(_usdc).safeApprove(_pool, type(uint256).max);
        IERC20(_weth).safeApprove(_pool, type(uint256).max);
        // Approve max USDC to SwapRouter for flash loan USDC→WETH swap
        IERC20(_usdc).safeApprove(_swapRouter, type(uint256).max);
    }

    // ===== ATOMIC SETTLEMENT (called by Vault during withdraw) =====

    /// @notice Settle AAVE hedge proportionally during atomic withdraw
    /// @dev Called by the vault after LP burn. WETH must be transferred to this contract before calling.
    ///      If WETH received < debt to repay, initiates flash loan to cover shortfall.
    /// @param wethReceived Amount of WETH transferred by vault (from LP burn)
    /// @param proportionBps Proportion of total position to settle (10000 = 100%)
    /// @param isFullWithdraw True if this is a full withdrawal (close entire position)
    /// @param recipient Address to send recovered USDC (typically the vault)
    function settleProportional(
        uint256 wethReceived,
        uint256 proportionBps,
        bool isFullWithdraw,
        address recipient
    ) external onlyVault whenNotPaused nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(proportionBps > 0 && proportionBps <= 10000, "Invalid proportion");

        // Get current WETH debt
        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));

        // If no debt, just send back any USDC collateral proportionally
        if (totalDebt == 0) {
            if (isFullWithdraw) {
                // Withdraw all USDC collateral
                pool.withdraw(address(usdc), type(uint256).max, recipient);
            } else if (proportionBps > 0) {
                // Get total collateral to calculate proportional amount
                (uint256 totalCollateralBase, , , , ,) = pool.getUserAccountData(address(this));
                if (totalCollateralBase > 0) {
                    // Withdraw proportional USDC collateral
                    // We use type(uint256).max for full, or calculate proportional
                    uint256 usdcBal = usdc.balanceOf(address(this));
                    pool.withdraw(address(usdc), type(uint256).max, address(this));
                    uint256 totalUsdcWithdrawn = usdc.balanceOf(address(this)) - usdcBal;
                    uint256 proportionalUsdc = (totalUsdcWithdrawn * proportionBps) / 10000;
                    // Re-supply the remainder
                    uint256 toResupply = totalUsdcWithdrawn - proportionalUsdc;
                    if (toResupply > 0) {
                        pool.supply(address(usdc), toResupply, address(this), 0);
                    }
                    if (proportionalUsdc > 0) {
                        usdc.safeTransfer(recipient, proportionalUsdc);
                    }
                }
            }
            // Send back any WETH that was received (not needed for repay)
            uint256 wethBal = weth.balanceOf(address(this));
            if (wethBal > 0) {
                weth.safeTransfer(recipient, wethBal);
            }
            emit SettleProportional(0, proportionBps, recipient, usdc.balanceOf(address(this)));
            return;
        }

        // Calculate debt to repay
        uint256 debtToRepay;
        if (isFullWithdraw) {
            debtToRepay = totalDebt;
        } else {
            debtToRepay = (totalDebt * proportionBps) / 10000;
        }

        uint256 wethAvailable = weth.balanceOf(address(this));

        if (wethAvailable >= debtToRepay) {
            // Happy path: enough WETH to repay directly
            _settleDirectly(debtToRepay, proportionBps, isFullWithdraw, recipient);
        } else {
            // Shortfall: need flash loan + USDC→WETH swap to cover repayment
            // Flash loan the exact shortfall. The executeOperation callback will:
            //   1. Repay AAVE debt with wethFromLP + flashLoaned WETH
            //   2. Withdraw USDC collateral from AAVE
            //   3. Swap just enough USDC → WETH to repay flash loan (amount + premium)
            //   4. Send remaining USDC to vault
            uint256 shortfall = debtToRepay - wethAvailable;

            _flashLoanActive = true;
            bytes memory params = abi.encode(debtToRepay, proportionBps, isFullWithdraw, recipient);
            pool.flashLoanSimple(address(this), address(weth), shortfall, params, 0);
            _flashLoanActive = false;
        }

        // Send any remaining WETH dust back to recipient
        uint256 remainingWeth = weth.balanceOf(address(this));
        if (remainingWeth > 0) {
            weth.safeTransfer(recipient, remainingWeth);
        }

        emit SettleProportional(wethReceived, proportionBps, recipient, 0);
    }

    /// @notice Emergency settle called by vault during EmergencyRecoverUser
    /// @dev Same as settleProportional but works even when paused.
    ///      Uses the same flash loan + swap logic as executeOperation.
    function emergencySettleForVault(
        uint256,
        uint256 proportionBps,
        bool isFullWithdraw,
        address recipient
    ) external onlyVault nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(proportionBps > 0 && proportionBps <= 10000, "Invalid proportion");

        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));

        if (totalDebt == 0) {
            if (isFullWithdraw) {
                pool.withdraw(address(usdc), type(uint256).max, recipient);
            } else {
                uint256 usdcBal = usdc.balanceOf(address(this));
                pool.withdraw(address(usdc), type(uint256).max, address(this));
                uint256 totalUsdcWithdrawn = usdc.balanceOf(address(this)) - usdcBal;
                uint256 proportionalUsdc = (totalUsdcWithdrawn * proportionBps) / 10000;
                uint256 toResupply = totalUsdcWithdrawn - proportionalUsdc;
                if (toResupply > 0) pool.supply(address(usdc), toResupply, address(this), 0);
                if (proportionalUsdc > 0) usdc.safeTransfer(recipient, proportionalUsdc);
            }
            uint256 wethBal = weth.balanceOf(address(this));
            if (wethBal > 0) weth.safeTransfer(recipient, wethBal);
            return;
        }

        uint256 debtToRepay = isFullWithdraw ? totalDebt : (totalDebt * proportionBps) / 10000;
        uint256 wethAvailable = weth.balanceOf(address(this));

        if (wethAvailable >= debtToRepay) {
            _settleDirectly(debtToRepay, proportionBps, isFullWithdraw, recipient);
        } else {
            // Flash loan the exact shortfall (swap covers repayment in executeOperation)
            uint256 shortfall = debtToRepay - wethAvailable;
            _flashLoanActive = true;
            bytes memory params = abi.encode(debtToRepay, proportionBps, isFullWithdraw, recipient);
            pool.flashLoanSimple(address(this), address(weth), shortfall, params, 0);
            _flashLoanActive = false;
        }

        uint256 remainingWeth = weth.balanceOf(address(this));
        if (remainingWeth > 0) weth.safeTransfer(recipient, remainingWeth);
    }

    /// @notice AAVE V3 flash loan callback
    /// @dev Called by AAVE Pool during flashLoanSimple. Repays debt, withdraws collateral,
    ///      swaps USDC→WETH to cover flash loan repayment, then sends remaining USDC to vault.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(pool), "Only AAVE Pool");
        require(initiator == address(this), "Invalid initiator");
        require(_flashLoanActive, "No active flash loan");
        require(asset == address(weth), "Wrong asset");

        (uint256 debtToRepay, uint256 proportionBps, bool isFullWithdraw, address recipient) =
            abi.decode(params, (uint256, uint256, bool, address));

        // Step 1: Repay WETH debt (we now have wethFromLP + flashLoan amount)
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // Step 2: Withdraw USDC collateral proportionally
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, address(this));
        } else {
            // Calculate proportional USDC to withdraw based on current AAVE collateral.
            // After partial debt repay, remaining debt prevents full collateral withdrawal
            // (AAVE would revert with HF < 1). Use getUserAccountData to get actual collateral.
            (uint256 totalCollateralBase, , , , ,) = pool.getUserAccountData(address(this));
            // totalCollateralBase is USD with 8 decimals, USDC has 6 decimals
            uint256 proportionalUsdc = (totalCollateralBase * proportionBps) / (10000 * 1e2);
            if (proportionalUsdc > 0) {
                pool.withdraw(address(usdc), proportionalUsdc, address(this));
            }
        }

        // Step 3: Swap USDC → WETH to cover flash loan repayment
        // After repaying AAVE debt, we have ~0 WETH but AAVE needs amount + premium back.
        // We swap just enough USDC to get the required WETH for flash loan repayment.
        uint256 flashLoanOwed = amount + premium;
        uint256 wethBalance = weth.balanceOf(address(this));

        if (wethBalance < flashLoanOwed) {
            uint256 wethNeeded = flashLoanOwed - wethBalance;
            // exactOutputSingle: swap minimum USDC to get exactly wethNeeded WETH
            swapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(weth),
                    fee: swapPoolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: wethNeeded,
                    amountInMaximum: usdc.balanceOf(address(this)), // use all available USDC as max
                    sqrtPriceLimitX96: 0
                })
            );
        }
        // AAVE will pull flashLoanOwed WETH from this contract (max approve in constructor)

        // Step 4: Send recovered USDC to recipient (vault)
        uint256 usdcToSend = usdc.balanceOf(address(this));
        if (usdcToSend > 0) {
            usdc.safeTransfer(recipient, usdcToSend);
        }

        return true;
    }

    // ===== MAIN FUNCTIONS =====

    /// @notice Supply all held USDC as collateral and borrow WETH
    /// @dev Used for initial hedge setup after deposit.
    ///      Flow: Vault sends USDC here -> this supplies to AAVE -> borrows WETH -> WETH stays here for sweep
    /// @param borrowAmountWeth Amount of WETH to borrow (in wei, 18 decimals)
    function supplyAndBorrow(uint256 borrowAmountWeth) external onlySafe whenNotPaused nonReentrant {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance > 0, "No USDC to supply");
        require(borrowAmountWeth > 0, "Zero borrow");

        // Supply all USDC as collateral
        pool.supply(address(usdc), usdcBalance, address(this), 0);

        // Borrow WETH (variable rate = 2)
        pool.borrow(address(weth), borrowAmountWeth, 2, 0, address(this));

        emit SupplyAndBorrow(usdcBalance, borrowAmountWeth);
    }

    /// @notice Borrow additional WETH (after new collateral has been supplied)
    /// @dev Used when ETH exposure increases after rebalance or new deposit
    /// @param borrowAmountWeth Amount of WETH to borrow additionally
    function borrowMore(uint256 borrowAmountWeth) external onlySafe whenNotPaused nonReentrant {
        require(borrowAmountWeth > 0, "Zero borrow");

        // Supply any pending USDC first (if vault sent more collateral)
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            pool.supply(address(usdc), usdcBalance, address(this), 0);
        }

        // Borrow more WETH
        pool.borrow(address(weth), borrowAmountWeth, 2, 0, address(this));

        emit BorrowMore(borrowAmountWeth);
    }

    /// @notice Repay WETH debt and withdraw USDC collateral
    /// @dev Used after user withdrawal -- watcher sends WETH here, then calls this
    /// @param repayAmountWeth Amount of WETH to repay (must be on this contract)
    /// @param withdrawAmountUsdc Amount of USDC collateral to withdraw
    function repayAndWithdraw(uint256 repayAmountWeth, uint256 withdrawAmountUsdc) external onlySafe whenNotPaused nonReentrant {
        require(repayAmountWeth > 0 || withdrawAmountUsdc > 0, "Nothing to do");

        // Repay WETH debt
        if (repayAmountWeth > 0) {
            pool.repay(address(weth), repayAmountWeth, 2, address(this));
        }

        // Withdraw USDC collateral (stays on this contract for sweep)
        if (withdrawAmountUsdc > 0) {
            pool.withdraw(address(usdc), withdrawAmountUsdc, address(this));
        }

        emit RepayAndWithdraw(repayAmountWeth, withdrawAmountUsdc);
    }

    /// @notice Repay WETH debt only (no collateral withdrawal)
    /// @dev Used during rebalance when ETH exposure decreases
    /// @param repayAmountWeth Amount of WETH to repay
    function repayDebt(uint256 repayAmountWeth) external onlySafe whenNotPaused nonReentrant {
        require(repayAmountWeth > 0, "Zero repay");

        pool.repay(address(weth), repayAmountWeth, 2, address(this));

        emit RepayDebt(repayAmountWeth);
    }

    /// @notice Withdraw USDC collateral to a specific address
    /// @dev Used to send recovered collateral to users
    /// @param amountUsdc Amount of USDC to withdraw from AAVE
    /// @param to Destination address
    function withdrawCollateral(uint256 amountUsdc, address to) external onlySafe whenNotPaused nonReentrant {
        require(amountUsdc > 0, "Zero withdraw");
        require(to != address(0), "Invalid recipient");

        pool.withdraw(address(usdc), amountUsdc, to);

        emit WithdrawCollateral(amountUsdc, to);
    }

    /// @notice Close entire position: repay all debt + withdraw all collateral
    /// @dev Used for full teardown. Sends all recovered USDC to recipient.
    ///      Requires enough WETH on this contract to repay full debt.
    /// @param recipient Address to receive all recovered USDC
    function closeAll(address recipient) external onlySafe whenNotPaused nonReentrant {
        require(recipient != address(0), "Invalid recipient");

        _closePosition(recipient);
    }

    /// @notice Emergency close: same as closeAll but works even when paused
    /// @param recipient Address to receive all recovered USDC
    function emergencyClose(address recipient) external onlySafe nonReentrant {
        require(recipient != address(0), "Invalid recipient");

        _closePosition(recipient);
    }

    /// @notice Send all WETH held on this contract to an address
    /// @dev Used after borrow to send WETH to RangeManager/Safe for LP constitution
    /// @param to Destination address (typically RangeManager or Safe)
    function sweepWeth(address to) external onlySafe whenNotPaused nonReentrant {
        require(to != address(0), "Invalid recipient");

        uint256 balance = weth.balanceOf(address(this));
        require(balance > 0, "No WETH to sweep");

        weth.safeTransfer(to, balance);

        emit SweepWeth(to, balance);
    }

    /// @notice Send all USDC held on this contract to an address
    /// @dev Used to recover USDC after collateral withdrawal
    /// @param to Destination address
    function sweepUsdc(address to) external onlySafe whenNotPaused nonReentrant {
        require(to != address(0), "Invalid recipient");

        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No USDC to sweep");

        usdc.safeTransfer(to, balance);

        emit SweepUsdc(to, balance);
    }

    // ===== ADMIN =====

    function setPaused(bool _paused) external onlySafe {
        paused = _paused;
        emit Paused(_paused);
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Get the health factor of this contract's AAVE position
    /// @return healthFactor in 1e18 scale (1e18 = 1.0, < 1e18 = liquidatable)
    function getHealthFactor() external view returns (uint256) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Get full hedge data for dashboard
    /// @return totalCollateralBase Total collateral in base currency (USD, 8 decimals)
    /// @return totalDebtBase Total debt in base currency (USD, 8 decimals)
    /// @return healthFactor Health factor in 1e18 scale
    /// @return availableBorrowsBase Available borrows in base currency (USD, 8 decimals)
    function getHedgeData() external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 healthFactor,
        uint256 availableBorrowsBase
    ) {
        (totalCollateralBase, totalDebtBase, availableBorrowsBase, , , healthFactor) =
            pool.getUserAccountData(address(this));
    }

    /// @notice Get WETH balance held on this contract (ready for LP or repay)
    function getWethBalance() external view returns (uint256) {
        return weth.balanceOf(address(this));
    }

    /// @notice Get USDC balance held on this contract (ready to supply or send)
    function getUsdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Get current WETH debt (variable debt token balance)
    function getWethDebt() external view returns (uint256) {
        return variableDebtWeth.balanceOf(address(this));
    }

    // ===== INTERNAL =====

    /// @dev Settle hedge directly when enough WETH is available (no flash loan needed)
    function _settleDirectly(
        uint256 debtToRepay,
        uint256 proportionBps,
        bool isFullWithdraw,
        address recipient
    ) internal {
        // Repay WETH debt
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // Withdraw USDC collateral
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, recipient);
        } else {
            // Calculate proportional USDC to withdraw based on current AAVE collateral.
            // We cannot use type(uint256).max here because remaining debt prevents
            // full collateral withdrawal (AAVE would revert with HF < 1).
            (uint256 totalCollateralBase, , , , ,) = pool.getUserAccountData(address(this));
            // totalCollateralBase is USD with 8 decimals, USDC has 6 decimals
            uint256 proportionalUsdc = (totalCollateralBase * proportionBps) / (10000 * 1e2);
            if (proportionalUsdc > 0) {
                uint256 usdcBefore = usdc.balanceOf(address(this));
                pool.withdraw(address(usdc), proportionalUsdc, address(this));
                uint256 usdcWithdrawn = usdc.balanceOf(address(this)) - usdcBefore;
                if (usdcWithdrawn > 0) {
                    usdc.safeTransfer(recipient, usdcWithdrawn);
                }
            }
        }
    }

    /// @dev Internal close position logic shared by closeAll and emergencyClose
    function _closePosition(address recipient) internal {
        // Repay all WETH debt (use max uint to repay everything)
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            pool.repay(address(weth), wethBalance, 2, address(this));
        }

        // Withdraw all USDC collateral (use max uint to withdraw everything)
        pool.withdraw(address(usdc), type(uint256).max, address(this));

        // Send all USDC to recipient
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            usdc.safeTransfer(recipient, usdcBalance);
        }

        emit CloseAll(recipient, usdcBalance);
    }
}
