// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IGmxExchangeRouter.sol";
import "./interfaces/IGmxReader.sol";
import "./interfaces/IGmxDataStore.sol";

interface ITreasury {
    function payKeeperBounty(address keeper) external;
}

contract TradingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint256 private constant SHARE_MULTIPLIER = 1e12;     // 1 USDC (6 dec) → 1e18 shares de base

    // --- Immutables ---
    IERC20 public immutable usdc;

    // --- GMX Addresses (mutable — GMX v2 met à jour ses contrats) ---
    address public gmxExchangeRouter;
    address public gmxOrderVault;
    address public gmxReader;
    address public gmxDataStore;

    // --- Treasury & Commission ---
    address public treasuryAddress;
    uint256 public commissionRateBps; // 1000 = 10%

    // --- Bot Module ---
    address public botModule;

    // --- Keeper Bounty ---
    bool public keeperBountyEnabled;

    // --- Risk Management (on-chain enforced) ---
    uint256 public maxPositionSizeBps;     // max % du vault par position (default: 500 = 5%)
    uint256 public maxTotalExposureBps;    // max % du vault engagé total (default: 3000 = 30%)
    uint256 public maxLeverage;            // levier max (default: 5)
    uint256 public maxConcurrentPositions; // max positions ouvertes (default: 5)
    uint256 public minDeposit;              // dépôt minimum en USDC (6 decimales, default: 1e6 = 1 USDC)

    // --- Vault Accounting ---
    uint256 public totalShares;
    mapping(address => uint256) public userShares;

    // --- Time-Weighted Shares (distribution équitable des PnL) ---
    struct UserInfo {
        uint256 shares;
        uint256 timeWeightedShares;      // Accumulation shares × temps
        uint256 lastTimeUpdate;          // Dernier timestamp de mise à jour
        uint256 depositTimestamp;         // Timestamp du dernier dépôt (cooldown)
    }
    mapping(address => UserInfo) public userInfo;
    uint256 public totalTimeWeightedShares;
    uint256 public lastGlobalTimeUpdate;

    // --- Deposit Cooldown ---
    uint256 public depositCooldown; // Minimum entre dépôt et retrait (en secondes)

    // --- Position Tracking ---
    struct Position {
        address market;
        bool isLong;
        uint256 collateralAmount;
        uint256 sizeInUsd;
        uint256 entryPrice;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
        uint256 openTimestamp;
        bool isOpen;
    }

    mapping(bytes32 => Position) public positions;
    bytes32[] public activePositionKeys;
    uint256 public totalExposureUsd;
    uint256 public totalDeployedCollateral; // Collateral envoyé à GMX (track séparé)

    // --- Pending Settlements (commission asynchrone GMX) ---
    struct PendingSettlement {
        bytes32 positionKey;
        uint256 collateralAmount;   // Collateral initial de la position
        uint256 balanceBefore;      // Balance USDC avant l'ordre de fermeture
        uint256 timestamp;          // Quand l'ordre a été créé
        bool settled;               // True une fois la commission prélevée
    }
    PendingSettlement[] public pendingSettlements;

    // --- Withdrawal Queue (pour demandes dépassant la liquidité idle) ---
    struct WithdrawalRequest {
        address user;
        uint256 shares;
        uint256 timestamp;
        bool fulfilled;
    }
    WithdrawalRequest[] public withdrawalQueue;
    uint256 public nextWithdrawalIndex;

    // --- Events ---
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event WithdrawalQueued(address indexed user, uint256 shares, uint256 index);
    event WithdrawalFulfilled(address indexed user, uint256 amount, uint256 shares, uint256 index);
    event PositionOpened(bytes32 indexed key, address market, bool isLong, uint256 collateral, uint256 sizeInUsd);
    event PositionClosed(bytes32 indexed key);
    event SettlementProcessed(bytes32 indexed positionKey, int256 pnl, uint256 commission);
    event StopLossUpdated(bytes32 indexed key, uint256 newPrice);
    event TakeProfitUpdated(bytes32 indexed key, uint256 newPrice);
    event StopLossExecuted(bytes32 indexed key, address indexed executor, uint256 price);
    event TakeProfitExecuted(bytes32 indexed key, address indexed executor, uint256 price);
    event PositionLiquidated(bytes32 indexed key, address indexed executor);
    event CommissionPaid(address indexed treasury, uint256 amount);
    event KeeperBountyPaid(address indexed keeper);
    event GmxExchangeRouterUpdated(address indexed oldAddr, address indexed newAddr);
    event GmxOrderVaultUpdated(address indexed oldAddr, address indexed newAddr);
    event GmxReaderUpdated(address indexed oldAddr, address indexed newAddr);
    event GmxDataStoreUpdated(address indexed oldAddr, address indexed newAddr);
    event CommissionRateUpdated(uint256 oldRate, uint256 newRate);
    event TreasuryAddressUpdated(address indexed oldAddr, address indexed newAddr);
    event BotModuleUpdated(address indexed oldModule, address indexed newModule);
    event KeeperBountyToggled(bool enabled);
    event MaxPositionSizeUpdated(uint256 oldBps, uint256 newBps);
    event MaxTotalExposureUpdated(uint256 oldBps, uint256 newBps);
    event MaxLeverageUpdated(uint256 oldMax, uint256 newMax);
    event MaxConcurrentPositionsUpdated(uint256 oldMax, uint256 newMax);
    event DepositCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);

    // --- Modifiers ---

    modifier onlyBot() {
        require(msg.sender == botModule, "Only bot module");
        _;
    }

    // --- Constructor ---

    constructor(
        address _usdc,
        address _gmxExchangeRouter,
        address _gmxOrderVault,
        address _gmxReader,
        address _gmxDataStore,
        address _treasuryAddress,
        uint256 _commissionRateBps,
        uint256 _maxPositionSizeBps,
        uint256 _maxTotalExposureBps,
        uint256 _maxLeverage,
        uint256 _maxConcurrentPositions,
        uint256 _minDeposit
    ) {
        usdc = IERC20(_usdc);
        gmxExchangeRouter = _gmxExchangeRouter;
        gmxOrderVault = _gmxOrderVault;
        gmxReader = _gmxReader;
        gmxDataStore = _gmxDataStore;
        treasuryAddress = _treasuryAddress;
        commissionRateBps = _commissionRateBps;
        maxPositionSizeBps = _maxPositionSizeBps;
        maxTotalExposureBps = _maxTotalExposureBps;
        maxLeverage = _maxLeverage;
        maxConcurrentPositions = _maxConcurrentPositions;
        minDeposit = _minDeposit;
        depositCooldown = 1 hours; // Valeur par défaut, modifiable via setDepositCooldown avant transferOwnership
        keeperBountyEnabled = false;
        lastGlobalTimeUpdate = block.timestamp;
    }

    receive() external payable {}

    // ============================================
    // Vault Functions (deposit/withdraw)
    // ============================================

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= minDeposit, "Below min deposit");
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares;
        // totalAssets() inclut le montant qui vient d'être transféré
        uint256 assetsBefore = totalAssets() - amount;

        if (totalShares == 0 || assetsBefore <= 1) {
            // Premier dépôt ou vault vidé → ratio 1:SHARE_MULTIPLIER
            if (totalShares > 0 && assetsBefore <= 1) {
                totalShares = 0; // Reset shares orphelines d'un vault vidé
            }
            shares = amount * SHARE_MULTIPLIER;
        } else {
            // Dépôt proportionnel aux assets existants
            shares = (amount * totalShares) / assetsBefore;
        }

        require(shares > 0, "Zero shares");

        // Mettre à jour time-weighted shares AVANT de modifier les shares
        _updateUserTimeWeightedShares(msg.sender);
        _updateGlobalTimeWeightedShares();

        userShares[msg.sender] += shares;
        totalShares += shares;

        // Enregistrer le timestamp de dépôt (cooldown)
        UserInfo storage info = userInfo[msg.sender];
        info.shares = userShares[msg.sender];
        info.depositTimestamp = block.timestamp;

        emit Deposit(msg.sender, amount, shares);
    }

    /**
     * Retrait standard : retire uniquement de la liquidité idle (USDC dans le vault).
     * Si le montant demandé dépasse la liquidité idle, le retrait est mis en queue
     * et sera exécuté automatiquement quand des positions seront fermées.
     */
    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0, "Zero shares");
        require(userShares[msg.sender] >= shares, "Insufficient shares");

        // Vérifier le cooldown (anti front-running des profits)
        UserInfo storage info = userInfo[msg.sender];
        require(
            block.timestamp >= info.depositTimestamp + depositCooldown,
            "Deposit cooldown active"
        );

        // Calculer la valeur en USDC (basée sur totalAssets qui inclut le deployed)
        uint256 amount = (shares * totalAssets()) / totalShares;
        require(amount > 0, "Zero amount");

        uint256 idleBalance = usdc.balanceOf(address(this));

        if (amount <= idleBalance) {
            // Assez de liquidité idle → retrait immédiat
            _executeWithdraw(msg.sender, shares, amount);
        } else if (idleBalance > 0 && activePositionKeys.length > 0) {
            // Retrait partiel de ce qui est disponible + queue pour le reste
            uint256 idleShares = (idleBalance * totalShares) / totalAssets();
            if (idleShares > shares) idleShares = shares;
            uint256 idleAmount = (idleShares * totalAssets()) / totalShares;

            if (idleAmount > 0 && idleShares > 0) {
                _executeWithdraw(msg.sender, idleShares, idleAmount);
            }

            uint256 remainingShares = shares - idleShares;
            if (remainingShares > 0) {
                _queueWithdrawal(msg.sender, remainingShares);
            }
        } else if (activePositionKeys.length > 0) {
            // Pas de liquidité idle, positions ouvertes → queue
            _queueWithdrawal(msg.sender, shares);
        } else {
            // Pas de positions et pas assez de USDC → erreur (ne devrait pas arriver)
            revert("Insufficient vault balance");
        }
    }

    /**
     * totalAssets inclut le USDC idle + le collateral déployé dans les positions GMX.
     * Note: ne tient pas compte du PnL non réalisé (volontairement conservateur).
     * Le PnL est intégré au retour des USDC après fermeture de position.
     */
    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalDeployedCollateral;
    }

    function getActivePositionCount() external view returns (uint256) {
        return activePositionKeys.length;
    }

    function getIdleBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function getWithdrawalQueueLength() external view returns (uint256) {
        return withdrawalQueue.length - nextWithdrawalIndex;
    }

    function getUserShareValue(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (userShares[user] * totalAssets()) / totalShares;
    }

    // ============================================
    // Bot Functions (via TradingBotModule → Safe)
    // ============================================

    struct OpenPositionParams {
        address market;
        bool isLong;
        uint256 collateralAmount;
        uint256 sizeInUsd;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
    }

    function openPosition(
        address market,
        bool isLong,
        uint256 collateralAmount,
        uint256 sizeInUsd,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 stopLossPrice,
        uint256 takeProfitPrice
    ) external payable onlyBot nonReentrant returns (bytes32) {
        return _openPositionInternal(OpenPositionParams({
            market: market,
            isLong: isLong,
            collateralAmount: collateralAmount,
            sizeInUsd: sizeInUsd,
            acceptablePrice: acceptablePrice,
            executionFee: executionFee,
            stopLossPrice: stopLossPrice,
            takeProfitPrice: takeProfitPrice
        }));
    }

    function _openPositionInternal(OpenPositionParams memory p) internal returns (bytes32) {
        // === On-chain risk checks ===
        uint256 vaultTotal = totalAssets();
        require(vaultTotal > 0, "Vault empty");
        require(activePositionKeys.length < maxConcurrentPositions, "Max positions reached");
        require(p.collateralAmount * 10000 / vaultTotal <= maxPositionSizeBps, "Position too large");
        require(totalExposureUsd + p.sizeInUsd <= vaultTotal * maxTotalExposureBps / 10000 * 1e24, "Max exposure exceeded");
        require(p.sizeInUsd / (p.collateralAmount * 1e24) <= maxLeverage, "Max leverage exceeded");
        require(usdc.balanceOf(address(this)) >= p.collateralAmount, "Insufficient idle USDC");

        // Send collateral + execution fee to GMX
        _sendToGmx(p.collateralAmount, p.executionFee);

        // Create order
        bytes32 key = _createGmxIncreaseOrder(p);

        // Store position
        positions[key] = Position({
            market: p.market,
            isLong: p.isLong,
            collateralAmount: p.collateralAmount,
            sizeInUsd: p.sizeInUsd,
            entryPrice: p.acceptablePrice,
            stopLossPrice: p.stopLossPrice,
            takeProfitPrice: p.takeProfitPrice,
            openTimestamp: block.timestamp,
            isOpen: true
        });

        activePositionKeys.push(key);
        totalExposureUsd += p.sizeInUsd;
        totalDeployedCollateral += p.collateralAmount;

        emit PositionOpened(key, p.market, p.isLong, p.collateralAmount, p.sizeInUsd);
        return key;
    }

    function _sendToGmx(uint256 collateralAmount, uint256 executionFee) internal {
        usdc.safeApprove(gmxOrderVault, 0);
        usdc.safeApprove(gmxOrderVault, collateralAmount);
        IGmxExchangeRouter(gmxExchangeRouter).sendTokens(
            address(usdc), gmxOrderVault, collateralAmount
        );
        IGmxExchangeRouter(gmxExchangeRouter).sendWnt{value: executionFee}(
            gmxOrderVault, executionFee
        );
    }

    function _createGmxIncreaseOrder(OpenPositionParams memory p) internal returns (bytes32) {
        address[] memory swapPath = new address[](0);

        IGmxExchangeRouter.CreateOrderParams memory params = IGmxExchangeRouter.CreateOrderParams({
            addresses: IGmxExchangeRouter.CreateOrderParamsAddresses({
                receiver: address(this),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: p.market,
                initialCollateralToken: address(usdc),
                swapPath: swapPath
            }),
            numbers: IGmxExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: p.sizeInUsd,
                initialCollateralDeltaAmount: p.collateralAmount,
                triggerPrice: 0,
                acceptablePrice: p.acceptablePrice,
                executionFee: p.executionFee,
                callbackGasLimit: 0,
                minOutputAmount: 0
            }),
            orderType: IGmxExchangeRouter.OrderType.MarketIncrease,
            decreasePositionSwapType: IGmxExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: p.isLong,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        return IGmxExchangeRouter(gmxExchangeRouter).createOrder(params);
    }

    function closePosition(bytes32 key) external onlyBot nonReentrant {
        _closePositionOnGmx(key);
    }

    function updateStopLoss(bytes32 key, uint256 newPrice) external onlyBot {
        Position storage pos = positions[key];
        require(pos.isOpen, "Position not open");
        pos.stopLossPrice = newPrice;
        emit StopLossUpdated(key, newPrice);
    }

    function updateTakeProfit(bytes32 key, uint256 newPrice) external onlyBot {
        Position storage pos = positions[key];
        require(pos.isOpen, "Position not open");
        pos.takeProfitPrice = newPrice;
        emit TakeProfitUpdated(key, newPrice);
    }

    // ============================================
    // Public Keeper Functions
    // ============================================

    function executeStopLoss(bytes32 key) external nonReentrant {
        Position storage pos = positions[key];
        require(pos.isOpen, "Not open");
        require(pos.stopLossPrice > 0, "No SL set");

        uint256 currentPrice = _getPositionPrice(key);
        if (pos.isLong) {
            require(currentPrice <= pos.stopLossPrice, "SL not triggered");
        } else {
            require(currentPrice >= pos.stopLossPrice, "SL not triggered");
        }

        _closePositionOnGmx(key);
        _payKeeperBounty(msg.sender);

        emit StopLossExecuted(key, msg.sender, currentPrice);
    }

    function executeTakeProfit(bytes32 key) external nonReentrant {
        Position storage pos = positions[key];
        require(pos.isOpen, "Not open");
        require(pos.takeProfitPrice > 0, "No TP set");

        uint256 currentPrice = _getPositionPrice(key);
        if (pos.isLong) {
            require(currentPrice >= pos.takeProfitPrice, "TP not triggered");
        } else {
            require(currentPrice <= pos.takeProfitPrice, "TP not triggered");
        }

        _closePositionOnGmx(key);
        _payKeeperBounty(msg.sender);

        emit TakeProfitExecuted(key, msg.sender, currentPrice);
    }

    function liquidatePosition(bytes32 key) external nonReentrant {
        Position storage pos = positions[key];
        require(pos.isOpen, "Not open");

        // Vérifier que la position est en situation de liquidation
        IGmxReader.PositionProps memory gmxPos = IGmxReader(gmxReader).getPosition(gmxDataStore, key);
        uint256 collateral = gmxPos.numbers.collateralAmount;
        uint256 sizeInUsd = gmxPos.numbers.sizeInUsd;

        // Liquidation si collateral < 1% de sizeInUsd (maintenance margin)
        uint256 maintenanceMargin = sizeInUsd / 100;
        require(collateral * 1e24 <= maintenanceMargin, "Not liquidatable");

        _closePositionOnGmx(key);
        _payKeeperBounty(msg.sender);

        emit PositionLiquidated(key, msg.sender);
    }

    // ============================================
    // Settlement — Commission asynchrone GMX
    // ============================================

    /**
     * Appelé par le bot (ou n'importe qui) après qu'un ordre GMX de fermeture
     * a été exécuté et que les USDC sont revenus dans le vault.
     * Calcule le PnL réel et prélève la commission sur le profit net.
     */
    function settlePosition(uint256 settlementIndex) external nonReentrant {
        require(settlementIndex < pendingSettlements.length, "Invalid index");
        PendingSettlement storage settlement = pendingSettlements[settlementIndex];
        require(!settlement.settled, "Already settled");

        // Vérifier que la position est bien fermée sur GMX (pas d'ordre en attente)
        Position storage pos = positions[settlement.positionKey];
        require(!pos.isOpen, "Position still open");

        uint256 currentBalance = usdc.balanceOf(address(this));

        // Le PnL est la différence entre le balance actuel et ce qu'on avait avant
        // Plus le collateral qui est revenu (était compté dans totalDeployedCollateral)
        int256 pnl = int256(currentBalance) - int256(settlement.balanceBefore);

        uint256 commission = 0;
        if (pnl > 0) {
            // Profit net = gain total - collateral retourné (déjà compté dans le retour)
            // Ici pnl > 0 signifie qu'on a reçu plus que ce qu'on avait avant l'envoi de l'ordre
            // Le collateral faisait déjà partie du vault avant, donc le profit est bien pnl
            uint256 netProfit = uint256(pnl);
            if (netProfit > settlement.collateralAmount) {
                // Le profit réel est au-delà du retour du collateral
                uint256 tradingProfit = netProfit - settlement.collateralAmount;
                commission = _handleCommission(tradingProfit);
            }
        }

        settlement.settled = true;

        emit SettlementProcessed(settlement.positionKey, pnl, commission);

        // Traiter les retraits en attente maintenant qu'il y a de la liquidité
        _processWithdrawalQueue();
    }

    /**
     * Settle automatique : le bot appelle cette fonction après chaque fermeture GMX.
     * Parcourt les settlements non traités et règle ceux dont les USDC sont arrivés.
     */
    function settleAll() external nonReentrant {
        uint256 currentBalance = usdc.balanceOf(address(this));

        for (uint256 i = 0; i < pendingSettlements.length; i++) {
            PendingSettlement storage settlement = pendingSettlements[i];
            if (settlement.settled) continue;

            Position storage pos = positions[settlement.positionKey];
            if (pos.isOpen) continue; // Pas encore fermée

            // Si le balance a augmenté depuis l'ordre, on peut settle
            if (currentBalance >= settlement.balanceBefore) {
                int256 pnl = int256(currentBalance) - int256(settlement.balanceBefore);
                uint256 commission = 0;

                if (pnl > 0 && uint256(pnl) > settlement.collateralAmount) {
                    uint256 tradingProfit = uint256(pnl) - settlement.collateralAmount;
                    commission = _handleCommission(tradingProfit);
                    currentBalance = usdc.balanceOf(address(this)); // Refresh après transfer
                }

                settlement.settled = true;
                emit SettlementProcessed(settlement.positionKey, pnl, commission);
            }
        }

        _processWithdrawalQueue();
    }

    // ============================================
    // Internal Functions
    // ============================================

    function _closePositionOnGmx(bytes32 key) internal {
        Position storage pos = positions[key];
        require(pos.isOpen, "Not open");

        uint256 balanceBefore = usdc.balanceOf(address(this));

        // Create decrease order on GMX (asynchrone — les USDC arrivent plus tard)
        address[] memory swapPath = new address[](0);

        IGmxExchangeRouter.CreateOrderParams memory params = IGmxExchangeRouter.CreateOrderParams({
            addresses: IGmxExchangeRouter.CreateOrderParamsAddresses({
                receiver: address(this),
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: pos.market,
                initialCollateralToken: address(usdc),
                swapPath: swapPath
            }),
            numbers: IGmxExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: pos.sizeInUsd,
                initialCollateralDeltaAmount: pos.collateralAmount,
                triggerPrice: 0,
                acceptablePrice: 0,
                executionFee: 0,
                callbackGasLimit: 0,
                minOutputAmount: 0
            }),
            orderType: IGmxExchangeRouter.OrderType.MarketDecrease,
            decreasePositionSwapType: IGmxExchangeRouter.DecreasePositionSwapType.SwapPnlTokenToCollateralToken,
            isLong: pos.isLong,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        IGmxExchangeRouter(gmxExchangeRouter).createOrder(params);

        // Marquer la position comme fermée
        pos.isOpen = false;
        totalExposureUsd -= pos.sizeInUsd;
        totalDeployedCollateral -= pos.collateralAmount;
        _removeActivePositionKey(key);

        // Enregistrer un pending settlement (commission prélevée plus tard via settlePosition)
        pendingSettlements.push(PendingSettlement({
            positionKey: key,
            collateralAmount: pos.collateralAmount,
            balanceBefore: balanceBefore,
            timestamp: block.timestamp,
            settled: false
        }));

        emit PositionClosed(key);
    }

    function _executeWithdraw(address user, uint256 shares, uint256 amount) internal {
        // Mettre à jour time-weighted shares AVANT de modifier les shares
        _updateUserTimeWeightedShares(user);
        _updateGlobalTimeWeightedShares();

        userShares[user] -= shares;
        totalShares -= shares;

        UserInfo storage info = userInfo[user];
        info.shares = userShares[user];

        usdc.safeTransfer(user, amount);

        emit Withdraw(user, amount, shares);
    }

    function _queueWithdrawal(address user, uint256 shares) internal {
        withdrawalQueue.push(WithdrawalRequest({
            user: user,
            shares: shares,
            timestamp: block.timestamp,
            fulfilled: false
        }));

        emit WithdrawalQueued(user, shares, withdrawalQueue.length - 1);
    }

    /**
     * Traite les retraits en attente dans l'ordre FIFO quand de la liquidité est disponible.
     * Appelé automatiquement après chaque settlement.
     */
    function _processWithdrawalQueue() internal {
        uint256 idleBalance = usdc.balanceOf(address(this));

        while (nextWithdrawalIndex < withdrawalQueue.length && idleBalance > 0) {
            WithdrawalRequest storage req = withdrawalQueue[nextWithdrawalIndex];
            if (req.fulfilled) {
                nextWithdrawalIndex++;
                continue;
            }

            // Vérifier que l'user a encore les shares (il peut avoir fait un autre retrait)
            if (userShares[req.user] < req.shares) {
                req.shares = userShares[req.user];
            }

            if (req.shares == 0) {
                req.fulfilled = true;
                nextWithdrawalIndex++;
                continue;
            }

            uint256 amount = (req.shares * totalAssets()) / totalShares;
            if (amount == 0) {
                req.fulfilled = true;
                nextWithdrawalIndex++;
                continue;
            }

            if (amount <= idleBalance) {
                // Fulfill complet
                _executeWithdraw(req.user, req.shares, amount);
                req.fulfilled = true;
                idleBalance -= amount;
                emit WithdrawalFulfilled(req.user, amount, req.shares, nextWithdrawalIndex);
                nextWithdrawalIndex++;
            } else {
                // Fulfill partiel
                uint256 partialShares = (idleBalance * totalShares) / totalAssets();
                if (partialShares > req.shares) partialShares = req.shares;
                if (partialShares > 0) {
                    uint256 partialAmount = (partialShares * totalAssets()) / totalShares;
                    _executeWithdraw(req.user, partialShares, partialAmount);
                    req.shares -= partialShares;
                    idleBalance -= partialAmount;
                    emit WithdrawalFulfilled(req.user, partialAmount, partialShares, nextWithdrawalIndex);
                }
                break; // Plus de liquidité
            }
        }
    }

    function _handleCommission(uint256 profit) internal returns (uint256) {
        if (profit > 0 && commissionRateBps > 0 && treasuryAddress != address(0)) {
            uint256 commission = (profit * commissionRateBps) / 10000;
            if (commission > 0 && usdc.balanceOf(address(this)) >= commission) {
                usdc.safeTransfer(treasuryAddress, commission);
                emit CommissionPaid(treasuryAddress, commission);
                return commission;
            }
        }
        return 0;
    }

    function _payKeeperBounty(address keeper) internal {
        if (keeperBountyEnabled && treasuryAddress != address(0)) {
            try ITreasury(treasuryAddress).payKeeperBounty(keeper) {
                emit KeeperBountyPaid(keeper);
            } catch {
                // Bounty failure should not revert the position close
            }
        }
    }

    function _getPositionPrice(bytes32 key) internal view returns (uint256) {
        IGmxReader.PositionProps memory gmxPos = IGmxReader(gmxReader).getPosition(gmxDataStore, key);
        uint256 sizeInUsd = gmxPos.numbers.sizeInUsd;
        uint256 sizeInTokens = gmxPos.numbers.sizeInTokens;
        require(sizeInTokens > 0, "Invalid position");
        return sizeInUsd * 1e18 / sizeInTokens;
    }

    function _removeActivePositionKey(bytes32 key) internal {
        for (uint256 i = 0; i < activePositionKeys.length; i++) {
            if (activePositionKeys[i] == key) {
                activePositionKeys[i] = activePositionKeys[activePositionKeys.length - 1];
                activePositionKeys.pop();
                return;
            }
        }
    }

    // ============================================
    // Time-Weighted Shares
    // ============================================

    function _updateUserTimeWeightedShares(address user) internal {
        UserInfo storage info = userInfo[user];
        if (info.lastTimeUpdate > 0 && info.shares > 0) {
            uint256 timeDelta = block.timestamp - info.lastTimeUpdate;
            info.timeWeightedShares += info.shares * timeDelta;
        }
        info.lastTimeUpdate = block.timestamp;
    }

    function _updateGlobalTimeWeightedShares() internal {
        if (lastGlobalTimeUpdate > 0 && totalShares > 0) {
            uint256 timeDelta = block.timestamp - lastGlobalTimeUpdate;
            totalTimeWeightedShares += totalShares * timeDelta;
        }
        lastGlobalTimeUpdate = block.timestamp;
    }

    function getUserTimeWeightedSharePercent(address user) external view returns (uint256) {
        if (totalTimeWeightedShares == 0) return 0;
        UserInfo storage info = userInfo[user];
        uint256 userTWS = info.timeWeightedShares;
        if (info.lastTimeUpdate > 0 && info.shares > 0) {
            userTWS += info.shares * (block.timestamp - info.lastTimeUpdate);
        }
        uint256 globalTWS = totalTimeWeightedShares;
        if (lastGlobalTimeUpdate > 0 && totalShares > 0) {
            globalTWS += totalShares * (block.timestamp - lastGlobalTimeUpdate);
        }
        return (userTWS * 10000) / globalTWS; // en bps
    }

    // ============================================
    // Admin Functions (onlyOwner = Safe)
    // Phase 2 : transferOwnership vers un TimelockController externe
    // ============================================

    function setCommissionRate(uint256 _rate) external onlyOwner {
        require(_rate <= 5000, "Max 50%");
        emit CommissionRateUpdated(commissionRateBps, _rate);
        commissionRateBps = _rate;
    }

    function setTreasuryAddress(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        emit TreasuryAddressUpdated(treasuryAddress, _treasury);
        treasuryAddress = _treasury;
    }

    function setBotModule(address _module) external onlyOwner {
        emit BotModuleUpdated(botModule, _module);
        botModule = _module;
    }

    function setGmxExchangeRouter(address _new) external onlyOwner {
        require(_new != address(0), "Invalid address");
        emit GmxExchangeRouterUpdated(gmxExchangeRouter, _new);
        gmxExchangeRouter = _new;
    }

    function setGmxOrderVault(address _new) external onlyOwner {
        require(_new != address(0), "Invalid address");
        emit GmxOrderVaultUpdated(gmxOrderVault, _new);
        gmxOrderVault = _new;
    }

    function setGmxReader(address _new) external onlyOwner {
        require(_new != address(0), "Invalid address");
        emit GmxReaderUpdated(gmxReader, _new);
        gmxReader = _new;
    }

    function setGmxDataStore(address _new) external onlyOwner {
        require(_new != address(0), "Invalid address");
        emit GmxDataStoreUpdated(gmxDataStore, _new);
        gmxDataStore = _new;
    }

    function setKeeperBountyEnabled(bool _enabled) external onlyOwner {
        keeperBountyEnabled = _enabled;
        emit KeeperBountyToggled(_enabled);
    }

    function setMaxPositionSizeBps(uint256 _bps) external onlyOwner {
        require(_bps > 0 && _bps <= 10000, "Invalid bps");
        emit MaxPositionSizeUpdated(maxPositionSizeBps, _bps);
        maxPositionSizeBps = _bps;
    }

    function setMaxTotalExposureBps(uint256 _bps) external onlyOwner {
        require(_bps > 0 && _bps <= 10000, "Invalid bps");
        emit MaxTotalExposureUpdated(maxTotalExposureBps, _bps);
        maxTotalExposureBps = _bps;
    }

    function setMaxLeverage(uint256 _max) external onlyOwner {
        require(_max > 0 && _max <= 100, "Invalid leverage");
        emit MaxLeverageUpdated(maxLeverage, _max);
        maxLeverage = _max;
    }

    function setMaxConcurrentPositions(uint256 _max) external onlyOwner {
        require(_max > 0, "Invalid max");
        emit MaxConcurrentPositionsUpdated(maxConcurrentPositions, _max);
        maxConcurrentPositions = _max;
    }

    function setDepositCooldown(uint256 _cooldown) external onlyOwner {
        require(_cooldown <= 7 days, "Max 7 days");
        emit DepositCooldownUpdated(depositCooldown, _cooldown);
        depositCooldown = _cooldown;
    }

    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        emit MinDepositUpdated(minDeposit, _minDeposit);
        minDeposit = _minDeposit;
    }

    // --- Emergency ---

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueETH(uint256 amount, address payable to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * En cas d'urgence : forcer le traitement de la queue de retraits.
     * Peut être utile si settleAll n'a pas été appelé.
     */
    function processWithdrawalQueue() external onlyOwner {
        _processWithdrawalQueue();
    }
}
