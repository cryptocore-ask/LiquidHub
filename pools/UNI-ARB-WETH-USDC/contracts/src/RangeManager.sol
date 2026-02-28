// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";

interface ITreasury {
    function payKeeperBounty(address keeper) external;
}

interface IMultiUserVault {
    function isAuthorizedRecipient(address) external view returns (bool);
    function snapshotFees(uint256, uint256) external;
    function notifyFeesCollected(uint256 fees0, uint256 fees1) external;
    function getCurrentPortfolioValue() external view returns (uint256);
    function recordFeesCollected(uint256, uint256) external;
    function getUserCount() external view returns (uint256);
    function getUserAtIndex(uint256 index) external view returns (address);
    function totalShares() external view returns (uint256);
    function commissionRate() external view returns (uint256);
    function treasuryAddress() external view returns (address);
    function startRebalance() external;
    function endRebalance() external;
}

/**
 * @title RangeManager
 * @notice Manages Uniswap V3 liquidity positions for the MultiUserVault
 * @dev OWNERSHIP MODEL: This contract intentionally uses Ownable pattern.
 *      Ownership is NOT a security risk here - it's a requirement:
 *      - Owner (MultiUserVault) and Safe provide administrative control
 *      - Required for: oracle configuration, emergency withdrawals, protocol upgrades
 *      - Renouncing ownership would break critical vault operations
 *      - Additional safeguard: safeAddress (Gnosis multisig) has co-admin rights
 *      Security scanners may flag this as a risk, but for DeFi vault contracts
 *      managing user funds, administrative control is essential, not optional.
 */
contract RangeManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RangeOperations for *;

    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MIN_REBALANCE_INTERVAL = 300;
    uint256 private constant MAX_CONSECUTIVE_FAILURES = 5;
    uint256 private constant FAILURE_COOLDOWN = 30 minutes;

    // ===== SYSTEME D'AUTORISATION DOUBLE =====
    address public safeAddress;
    mapping(address => bool) public authorizedExecutors;
    
    event SafeAddressSet(address indexed safe);
    event ExecutorAuthorized(address indexed executor, bool authorized);

    // ===== VARIABLES IMMUTABLE =====
    
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    IUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;
    
    // ===== MULTI-USER VAULT INTEGRATION =====
    address public immutable vault;
    mapping(address => bool) public authorizedRecipients;

    // ===== SWAP & TREASURY =====
    ISwapRouter public immutable swapRouter;
    address public treasuryAddress;
    uint16 public swapFeeBps;
    uint256 public initMultiSwapTvl;

    // ===== VARIABLES D'ETAT (utilisant les structs de la library) =====
    
    RangeOperations.RangeConfig public config;
    RangeOperations.ProtectionConfig public protectionConfig;
    RangeOperations.PriceCache public priceCache;
    RangeOperations.SystemStats public systemStats;

    // ===== ORACLES =====

    AggregatorV3Interface private token0PriceFeed;
    AggregatorV3Interface private token1PriceFeed;
    AggregatorV3Interface private ethPriceFeed; // Oracle ETH/USD pour calcul des gas fees

    // ===== GESTION POSITIONS =====
    
    uint32 private positionCount;
    mapping(uint256 => uint32) private positionIndex;
    mapping(uint32 => uint256) private indexToPosition;
    mapping(uint256 => bool) private isOwnedPosition;

    // ===== PROTECTION ECHECS =====

    uint256 private consecutiveFailures;
    uint256 private _lastFailureTimestamp;

    // ===== EVENTS =====

    event PositionCreated(
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 totalValueUSD,
        string rangeMode
    );
    
    event TokenWithdrawn(address indexed token, uint256 amount, string reason);
    event PriceCacheUpdated(uint128 price0, uint128 price1, int24 poolTick);
    event ToleranceUpdated(uint16 oldToleranceBps, uint16 newToleranceBps);
    event LiquidityAdded(uint256 indexed tokenId, uint256 amount0, uint256 amount1, uint128 liquidity);

    // ===== NOUVEAUX MODIFIERS =====
    
    /**
     * @dev Modifier qui remplace onlyOwner pour les fonctions critiques
     * Permet l'exEcution par MultiUserVault (owner) OU par la Safe
     */
    modifier onlyAuthorized() {
        require(
            msg.sender == owner() ||
            msg.sender == safeAddress ||
            authorizedExecutors[msg.sender],
            "E99"
        );
        _;
    }
    
    /**
     * @dev Modifier strictement pour le owner (MultiUserVault)
     * Utilise pour les fonctions de gestion des autorisations
     */
    modifier onlyVaultOwner() {
        require(msg.sender == owner(), "E01");
        _;
    }

    modifier operationalChecks() {
        if (protectionConfig.failureProtectionEnabled) {
            require(consecutiveFailures < MAX_CONSECUTIVE_FAILURES ||
                    block.timestamp >= _lastFailureTimestamp + FAILURE_COOLDOWN,
                    "E02");
        }
        if (protectionConfig.mevProtectionEnabled) {
            require(block.timestamp - config.lastRebalanceTime >= MIN_REBALANCE_INTERVAL,
                    "E03");
        }
        require(config.oraclesConfigured, "E04");
        _;
    }

    modifier maxPositionsCheck() {
        require(positionCount < config.maxPositions, "E06");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "E07");
        _;
    }

    modifier onlyVaultOrOwner() {
        require(msg.sender == vault || msg.sender == owner(), "E08");
        _;
    }

    modifier onlyVaultOrAuthorized() {
        require(
            msg.sender == vault ||
            msg.sender == owner() ||
            msg.sender == safeAddress ||
            authorizedExecutors[msg.sender],
            "E94"
        );
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(
        address _vault,
        address _positionManager,
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee,
        uint8 _token0Decimals,
        uint8 _token1Decimals,
        address _swapRouter,
        address _treasuryAddress,
        uint16 _swapFeeBps,
        uint256 _initMultiSwapTvl,
        uint16 _rangeUpPercent,
        uint16 _rangeDownPercent
    ) {

        require(_vault != address(0), "E09");
        vault = _vault;

        require(_positionManager != address(0) &&
                _factory != address(0) && _token0 != address(0) &&
                _token1 != address(0) && _token0 != _token1 &&
                _token0 < _token1, "E10");

        // Validation des ranges (mêmes limites que configureRanges)
        require(_rangeUpPercent >= 10 && _rangeUpPercent <= 5000, "E17");
        require(_rangeDownPercent >= 10 && _rangeDownPercent <= 5000, "E18");

        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
        token0 = _token0;
        token1 = _token1;

        address poolAddress = IUniswapV3Factory(_factory).getPool(_token0, _token1, _fee);
        require(poolAddress != address(0), "E11");
        pool = IUniswapV3Pool(poolAddress);

        config = RangeOperations.RangeConfig({
            fee: _fee,
            token0Decimals: _token0Decimals,
            token1Decimals: _token1Decimals,
            toleranceBps: 25, //0,25% en basis points
            maxSlippageBps: 100, //1% en basis points
            lastRebalanceTime: 0,
            oraclesConfigured: false,
            rangeUpPercent: _rangeUpPercent,
            rangeDownPercent: _rangeDownPercent,
            maxPositions: 1
        });

        protectionConfig = RangeOperations.ProtectionConfig({
            sandwichDetectionEnabled: true,
            mevProtectionEnabled: true,
            failureProtectionEnabled: true,
            sandwichThresholdBps: 500,
            maxOracleDeviationBps: 500
        });

        systemStats.initialized = true;

        // Swap & Treasury config
        require(_swapRouter != address(0), "E51");
        swapRouter = ISwapRouter(_swapRouter);
        treasuryAddress = _treasuryAddress;
        swapFeeBps = _swapFeeBps;
        initMultiSwapTvl = _initMultiSwapTvl;

        // Approve SwapRouter for both tokens
        IERC20(_token0).approve(_swapRouter, type(uint256).max);
        IERC20(_token1).approve(_swapRouter, type(uint256).max);

        _transferOwnership(_vault);
    }

    // ===== FONCTIONS DE GESTION DES AUTORISATIONS =====

    /**
     * @notice Configure l'adresse de la Safe
     * @dev Ne peut etre appelE qu'une fois par le vault owner
     * @param _safe L'adresse de la Safe
     */
    function setSafeAddress(address _safe) external onlyVaultOwner {
        require(_safe != address(0), "E13");
        require(safeAddress == address(0), "E14");
        safeAddress = _safe;
        emit SafeAddressSet(_safe);
    }

    /**
     * @notice Autorise ou rEvoque un exEcuteur
     * @dev Peut etre appele par le vault owner ou la Safe
     * @param _executor L'adresse a autoriser/rEvoquer
     * @param _authorized True pour autoriser, false pour revoquer
     * @dev SECURITY NOTE: This function uses `msg.sender == owner() || msg.sender == safeAddress`
     *      instead of just `onlyOwner` intentionally. This dual-access pattern allows:
     *      - owner(): The vault owner for administrative control
     *      - safeAddress: The Gnosis Safe multisig for operational security
     *      This provides flexibility while maintaining security through two trusted entities.
     */
    function setAuthorizedExecutor(address _executor, bool _authorized) external {
        require(_executor != address(0), "E15");
        require(msg.sender == owner() || msg.sender == safeAddress, "E16"); // Dual access - see NatSpec
        authorizedExecutors[_executor] = _authorized;
        emit ExecutorAuthorized(_executor, _authorized);
    }

    // ===== FONCTIONS DE CONFIGURATION (modifiees avec onlyAuthorized) =====

    function configureRanges(uint16 _rangeUpPercent, uint16 _rangeDownPercent) external onlyAuthorized {
        require(_rangeUpPercent >= 10 && _rangeUpPercent <= 5000, "E17");
        require(_rangeDownPercent >= 10 && _rangeDownPercent <= 5000, "E18");

        config.rangeUpPercent = _rangeUpPercent;
        config.rangeDownPercent = _rangeDownPercent;
    }

    function configureSlippage(uint24 _maxSlippageBps) external onlyAuthorized {
        require(_maxSlippageBps >= 50 && _maxSlippageBps <= 500, "E19");
        config.maxSlippageBps = _maxSlippageBps;
    }

    function configureTolerance(uint16 _toleranceBps) external onlyAuthorized {
        require(_toleranceBps <= 1000, "E20");
        
        uint16 oldTolerance = config.toleranceBps;
        config.toleranceBps = _toleranceBps;
        
        emit ToleranceUpdated(oldTolerance, _toleranceBps);
    }

    function configureProtections(
        bool _sandwichDetection,
        bool _mevProtection,
        bool _failureProtection,
        uint16 _sandwichThresholdBps
    ) external onlyAuthorized {
        require(_sandwichThresholdBps <= 1000, "E21");

        protectionConfig.sandwichDetectionEnabled = _sandwichDetection;
        protectionConfig.mevProtectionEnabled = _mevProtection;
        protectionConfig.failureProtectionEnabled = _failureProtection;
        protectionConfig.sandwichThresholdBps = _sandwichThresholdBps;
    }

    function setMaxPositions(uint32 _maxPositions) external onlyAuthorized {
        require(_maxPositions > 0 && _maxPositions <= 10000, "E22");
        config.maxPositions = _maxPositions;
    }

    /**
     * @notice Configure les oracles de prix Chainlink
     * @dev SECURITY: Restricted to owner/safe only (not executors) because oracle addresses
     *      determine all pricing logic. Allowing executors to change oracles would be a security risk.
     *      The bot only calls updatePriceCache(), not this function.
     */
    function configurePriceFeeds(address _token0PriceFeed, address _token1PriceFeed, address _ethPriceFeed)
        external
    {
        require(msg.sender == owner() || msg.sender == safeAddress, "E16");
        require(_token0PriceFeed != address(0) && _token1PriceFeed != address(0) && _ethPriceFeed != address(0), "E23");

        token0PriceFeed = AggregatorV3Interface(_token0PriceFeed);
        token1PriceFeed = AggregatorV3Interface(_token1PriceFeed);
        ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);

        _updatePriceCache();

        config.oraclesConfigured = true;

        _recordSuccessfulOperation();
    }


    // ===== FONCTIONS PRINCIPALES (modifiees avec onlyAuthorized) =====

    function mintInitialPosition()
        external
        onlyAuthorized
        nonReentrant
        operationalChecks
        maxPositionsCheck
        returns (uint256 tokenId, uint128 liquidity)
    {
        require(config.oraclesConfigured, "E26");

        try this._mintInternal() returns (uint256 _tokenId, uint128 _liquidity) {
            _recordSuccessfulOperation();
            return (_tokenId, _liquidity);
        } catch (bytes memory reason) {
            _recordFailedOperation();

            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            } else {
                revert("E27");
            }
        }
    }

    // rebalancePosition supprimee - le rebalance se fait maintenant via:
    // 1. burnPosition() - collecte fees + retire liquidite
    // 2. executeSwap() x N - swaps via Uniswap V3
    // 3. mintInitialPosition() - mint nouvelle position

    /**
     * @notice Internal mint function - callable only via try/catch from this contract
     * @dev SECURITY NOTE: This function uses `external` visibility with `msg.sender == address(this)`
     *      check intentionally. This is a standard Solidity pattern for try/catch error handling.
     *      In Solidity, try/catch only works with external calls, so to catch errors from internal
     *      logic, we must:
     *      1. Make the function external
     *      2. Call it via `this._mintInternal()` (external call to self)
     *      3. Protect with `require(msg.sender == address(this))` to prevent external exploitation
     *      This is NOT a security vulnerability - it's a design pattern. The only entry point is
     *      mintInitialPosition() which is protected by onlyAuthorized modifier.
     * @return tokenId The ID of the newly minted position
     * @return liquidity The amount of liquidity minted
     */
    function _mintInternal() external returns (uint256 tokenId, uint128 liquidity) {
        require(msg.sender == address(this), "E29"); // Self-call only - see NatSpec above

        _updatePriceCache();

        // Verifier qu'on a des tokens a minter (swaps deja faits via executeSwap)
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        require(balance0 > 0 || balance1 > 0, "E30");

        // Calculer les ticks cibles
        (int24 tickLower, int24 tickUpper) = RangeOperations.calculateTargetTicks(priceCache, config, pool);

        // PAS DE SWAP ICI - les swaps sont faits via executeSwap (multi-swap) avant d'appeler cette fonction

        // Minter la nouvelle position avec les balances actuelles
        (tokenId, liquidity) = RangeOperations.mintNewPosition(
            token0,
            token1,
            config,
            tickLower,
            tickUpper,
            positionManager,
            address(this)
        );

        _addPosition(tokenId);

        uint256 totalValueUSD = _getCurrentPortfolioValue();
        config.lastRebalanceTime = uint64(block.timestamp);
        _updateSystemStats(totalValueUSD);

        emit PositionCreated(tokenId, tickLower, tickUpper, _safeUint128(totalValueUSD), "multi_swap_mint");

        return (tokenId, liquidity);
    }

    /**
     * @notice Retire de la liquidite pour un withdraw utilisateur
     */
    function removeLiquidityForWithdraw(uint256 tokenId, uint128 liquidityToRemove)
        external
        onlyVault
        nonReentrant
    {
        if (liquidityToRemove > 0) {
            // Sauvegarder les balances avant pour calculer les fees
            uint256 balanceBefore0 = IERC20(token0).balanceOf(address(this));
            uint256 balanceBefore1 = IERC20(token1).balanceOf(address(this));

            // Retirer la liquidite
            (uint256 amount0FromLiq, uint256 amount1FromLiq) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                })
            );

            // Collecter les tokens (principal + fees)
            positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            // Calculer les fees collectées (total reçu - principal)
            uint256 balanceAfter0 = IERC20(token0).balanceOf(address(this));
            uint256 balanceAfter1 = IERC20(token1).balanceOf(address(this));
            uint256 totalReceived0 = balanceAfter0 - balanceBefore0;
            uint256 totalReceived1 = balanceAfter1 - balanceBefore1;

            // Les fees = ce qu'on a reçu en plus du principal de la liquidité
            uint256 fees0 = totalReceived0 > amount0FromLiq ? totalReceived0 - amount0FromLiq : 0;
            uint256 fees1 = totalReceived1 > amount1FromLiq ? totalReceived1 - amount1FromLiq : 0;

            // IMPORTANT: Notifier le vault des fees collectées pour qu'elles soient trackées
            if (fees0 > 0 || fees1 > 0) {
                IMultiUserVault(vault).recordFeesCollected(fees0, fees1);
            }

            emit TokenWithdrawn(token0, 0, "Liquidity removed for withdrawal");
        }
    }
    
    /**
     * @notice Transfere les tokens pour un withdraw utilisateur
     */
    function transferTokensForWithdraw(
          uint256 amount0Requested,
          uint256 amount1Requested,
          address recipient
      ) external onlyVault returns (uint256 amount0Sent, uint256 amount1Sent) {
          // Recuperer les balances actuelles
          uint256 balance0 = IERC20(token0).balanceOf(address(this));
          uint256 balance1 = IERC20(token1).balanceOf(address(this));
          
          // SUPPRIMER COMPLÈTEMENT LES RÉSERVES
          amount0Sent = balance0 >= amount0Requested ? amount0Requested : balance0;
          amount1Sent = balance1 >= amount1Requested ? amount1Requested : balance1;
          
          // Transferer les tokens
          if (amount0Sent > 0) {
              IERC20(token0).safeTransfer(recipient, amount0Sent);
              emit TokenWithdrawn(token0, amount0Sent, "User withdrawal");
          }
          
          if (amount1Sent > 0) {
              IERC20(token1).safeTransfer(recipient, amount1Sent);
              emit TokenWithdrawn(token1, amount1Sent, "User withdrawal");
          }
          
          return (amount0Sent, amount1Sent);
      }

    /**
     * @notice Collecte les fees accumulées dans la position NFT et les envoie au vault
     * @dev Appelée par le vault avant un withdraw pour que l'utilisateur récupère ses pending fees
     * @return fees0 Montant de token0 collecté
     * @return fees1 Montant de token1 collecté
     */
    function collectFeesForVault() external onlyVault returns (uint256 fees0, uint256 fees1) {
        uint256[] memory positions = getOwnerPositions();
        if (positions.length == 0) return (0, 0);

        uint256 tokenId = positions[0];

        // Récupérer la liquidité actuelle
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);

        // Si liquidité > 0, crystalliser les fees (decreaseLiquidity avec 0)
        if (liquidity > 0) {
            try positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                })
            ) {} catch {}
        }

        // Collecter toutes les fees et les envoyer directement au vault
        try positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        ) returns (uint256 amount0, uint256 amount1) {
            fees0 = amount0;
            fees1 = amount1;
        } catch {
            fees0 = 0;
            fees1 = 0;
        }

        // Notifier le vault des fees collectées pour distribution
        if (fees0 > 0 || fees1 > 0) {
            IMultiUserVault(vault).recordFeesCollected(fees0, fees1);
            emit FeesCollectedForVault(fees0, fees1);
        }

        return (fees0, fees1);
    }

    event FeesCollectedForVault(uint256 fees0, uint256 fees1);

    /**
    * @notice Ajoute de la liquidite a la position existante
    * @dev Les swaps doivent etre faits AVANT via executeSwap (multi-swap) par le bot
    *      Cette fonction ajoute simplement la liquidite avec les balances actuelles
    */
    function addLiquidityToPosition() external onlyVaultOrAuthorized nonReentrant {
          uint256[] memory positions = getOwnerPositions();
          require(positions.length > 0, "E35");

          uint256 tokenId = positions[0];

          // Déléguer à la library SANS SWAP (les swaps sont faits avant via executeSwap)
          (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) =
              RangeOperations.addLiquidityWithoutSwap(
                  token0,
                  token1,
                  tokenId,
                  positionManager,
                  address(this)
              );

          emit LiquidityAdded(tokenId, amount0Added, amount1Added, liquidity);
      }  

    // ===== FONCTIONS DE CONSULTATION =====
    
    function getOwnerPositions() public view returns (uint256[] memory positions) {
        positions = new uint256[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = indexToPosition[uint32(i)];
        }
    }
    
    function getBotInstructions() external view returns (
        bool hasPosition,
        uint256 tokenId,
        bool shouldRebalance,
        string memory action,
        string memory reason
    ) {
        return RangeOperations.getBotInstructions(
            positionCount,
            config.maxPositions,
            consecutiveFailures,
            MAX_CONSECUTIVE_FAILURES,
            _lastFailureTimestamp,
            FAILURE_COOLDOWN,
            getOwnerPositions(),
            positionManager,
            priceCache
        );
    }
    
    /**
     * @notice Fonction publique pour calculer les target ticks (appelable par le bot)
     * @dev Utilise le cache prix interne mis a jour
     * @return tickLower Le tick inferieur calcule
     * @return tickUpper Le tick superieur calcule
     */
    function calculateTargetTicks() external view returns (int24 tickLower, int24 tickUpper) {
        // Verifier que le systeme est operationnel
        require(config.oraclesConfigured, "E37");
        require(priceCache.valid, "E38");

        // Utiliser la library avec le cache interne
        return RangeOperations.calculateTargetTicks(priceCache, config, pool);
    }

    /**
     * @notice Fonction publique pour verifier si une position est out of range
     * @param tokenId L'ID de la position a verifier
     * @return bool True si la position est hors du range
     */
    function isPositionOutOfRange(uint256 tokenId) external view returns (bool) {
        // Verifier que le cache est valide
        if (!priceCache.valid) {
            return false;
        }
        
        // Utiliser la library avec le cache interne
        return RangeOperations.isPositionOutOfRange(tokenId, positionManager, priceCache);
    }
    
    /**
     * @notice Fonction helper pour obtenir les details d'une position
     * @param tokenId L'ID de la position
     * @return inRange Si la position est dans le range
     * @return tickLower Le tick inferieur de la position
     * @return tickUpper Le tick superieur de la position
     * @return liquidity La liquidite de la position
     * @return currentTick Le tick actuel de la pool
     */
    function getPositionDetails(uint256 tokenId) external view returns (
        bool inRange,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 currentTick
    ) {
        if (!priceCache.valid) {
            return (false, 0, 0, 0, 0);
        }

        (,,,,,tickLower, tickUpper, liquidity,,,,) = positionManager.positions(tokenId);
        currentTick = priceCache.poolTick;
        inRange = (currentTick > tickLower && currentTick < tickUpper);

        return (inRange, tickLower, tickUpper, liquidity, currentTick);
    }
    
    function getCurrentBalances() external view returns (uint256 balance0, uint256 balance1) {
        // Récupérer les balances dans RangeManager + positions NFT
        // Cela inclut : tokens libres + liquidité active + tokensOwed (pending fees)
        (balance0, balance1) = RangeOperations.getCurrentBalances(
            token0,
            token1,
            address(this),
            getOwnerPositions(),
            positionManager,
            pool
        );
    }

    function isSystemOperational() external view returns (bool) {
        return config.oraclesConfigured &&
               priceCache.valid &&
               consecutiveFailures < MAX_CONSECUTIVE_FAILURES;
    }

    /**
     * @notice Calcule les parametres optimaux pour le swap avant mint/rebalance
     * @dev Delegue le calcul a la library RangeOperations
     */
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory) {
        require(config.oraclesConfigured, "E37");
        require(priceCache.valid, "E38");

        return RangeOperations.calculateOptimalSwapParams(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            priceCache,
            config,
            pool
        );
    }

    // ===== FONCTIONS INTERNES =====

    function _updatePriceCache() private {
        if (address(token0PriceFeed) == address(0) || address(token1PriceFeed) == address(0)) {
            priceCache.valid = false;
            return;
        }
        
        try token0PriceFeed.latestRoundData() returns (uint80, int256 price0, uint256, uint256, uint80) {
            try token1PriceFeed.latestRoundData() returns (uint80, int256 price1, uint256, uint256, uint80) {
                if (price0 <= 0 || price1 <= 0) {
                    priceCache.valid = false;
                    return;
                }
                
                try this._updatePriceCacheInternal() {
                    emit PriceCacheUpdated(priceCache.price0, priceCache.price1, priceCache.poolTick);
                } catch {
                    priceCache.valid = false;
                }
            } catch {
                priceCache.valid = false;
            }
        } catch {
            priceCache.valid = false;
        }
    }

    /**
     * @notice Internal price cache update function - callable only via try/catch from this contract
     * @dev SECURITY NOTE: This function uses `external` visibility with `msg.sender == address(this)`
     *      check intentionally. This is a standard Solidity pattern for try/catch error handling.
     *      In Solidity, try/catch only works with external calls, so to catch errors from internal
     *      logic, we must:
     *      1. Make the function external
     *      2. Call it via `this._updatePriceCacheInternal()` (external call to self)
     *      3. Protect with `require(msg.sender == address(this))` to prevent external exploitation
     *      This is NOT a security vulnerability - it's a design pattern. The only entry point is
     *      _updatePriceCache() which is called internally by other protected functions.
     */
    function _updatePriceCacheInternal() external {
        require(msg.sender == address(this), "E39"); // Self-call only - see NatSpec above
        // Utiliser la library pour calculer le nouveau cache
        RangeOperations.PriceCache memory newCache = RangeOperations.updatePriceCache(
            token0PriceFeed,
            token1PriceFeed,
            pool,
            config
        );
        // Mettre a jour le storage
        priceCache = newCache;
    }
    
    function _addPosition(uint256 tokenId) private {
        if (!isOwnedPosition[tokenId]) {
            uint32 index = positionCount++;
            positionIndex[tokenId] = index;
            indexToPosition[index] = tokenId;
            isOwnedPosition[tokenId] = true;
        }
    }

    function _removePosition(uint256 tokenId) private {
        if (isOwnedPosition[tokenId]) {
            uint32 index = positionIndex[tokenId];
            uint32 lastIndex = --positionCount;
            
            if (index != lastIndex) {
                uint256 lastTokenId = indexToPosition[lastIndex];
                indexToPosition[index] = lastTokenId;
                positionIndex[lastTokenId] = index;
            }
            
            delete indexToPosition[lastIndex];
            delete positionIndex[tokenId];
            delete isOwnedPosition[tokenId];
        }
    }
    
    function _recordSuccessfulOperation() private {
        systemStats.successfulOperations++;
        consecutiveFailures = 0;
        systemStats.consecutiveFailures = 0;
    }

    function _recordFailedOperation() private {
        systemStats.failedOperations++;
        consecutiveFailures++;
        systemStats.consecutiveFailures = uint32(consecutiveFailures);
        _lastFailureTimestamp = block.timestamp;
    }
    
    function _updateSystemStats(uint256 newValue) private {
        systemStats.totalRebalances++;
        systemStats.totalVolume += _safeUint128(newValue);
        systemStats.lastRebalanceBlock = uint64(block.number);
    }

    function _getCurrentPortfolioValue() private view returns (uint256) {
        return IMultiUserVault(vault).getCurrentPortfolioValue();
    }
    
    function _safeUint128(uint256 value) private pure returns (uint128) {
        require(value <= MAX_UINT128, "E40");
        return uint128(value);
    }

    /**
     * @notice Fonction d'urgence pour retirer des fonds pour un utilisateur
     * @dev Appelee uniquement par le Vault en cas d'urgence
     * @param amount0Requested Montant de token0 demande
     * @param amount1Requested Montant de token1 demande
     * @param recipient L'adresse qui recevra les tokens
     * @return amount0Sent Montant de token0 effectivement envoye
     * @return amount1Sent Montant de token1 effectivement envoye
     */
    function emergencyWithdrawForUser(
        uint256 amount0Requested,
        uint256 amount1Requested,
        address recipient
    ) external onlyVault nonReentrant returns (uint256 amount0Sent, uint256 amount1Sent) {
        require(recipient != address(0), "E41");
        
        // Recuperer les balances actuelles
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        
        amount0Sent = amount0Requested > balance0 ? balance0 : amount0Requested;
        amount1Sent = amount1Requested > balance1 ? balance1 : amount1Requested;
        
        // Transferer les tokens
        if (amount0Sent > 0) {
            IERC20(token0).safeTransfer(recipient, amount0Sent);
        }
        
        if (amount1Sent > 0) {
            IERC20(token1).safeTransfer(recipient, amount1Sent);
        }
        
        emit EmergencyWithdraw(
            recipient,
            amount0Sent,
            amount1Sent,
            msg.sender
        );
        
        return (amount0Sent, amount1Sent);
    }
    
    // Event pour emergencyWithdrawForUser
    event EmergencyWithdraw(
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        address indexed initiator
    );
    
    /**
     * @notice Burn une position NFT apres avoir retire toute la liquidite
     * @dev Appelee par le Vault ou les adresses autorisees (pour multi-swap)
     *      Collecte les fees et les transfère au vault (comme rebalancePosition)
     * @param tokenId L'ID de la position a burn
     */
    function burnPosition(uint256 tokenId)
        external
        onlyVaultOrAuthorized
        nonReentrant
    {
        // Verifier que la position existe et nous appartient
        require(isOwnedPosition[tokenId], "E42");

        // Recuperer les infos de la position
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,
        ) = positionManager.positions(tokenId);

        // 1. Collecter TOUTES les fees accumulees AVANT de retirer la liquidite
        // (exactement comme collectAndRemoveLiquidity dans RangeOperations)
        (uint256 fees0, uint256 fees1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // 2. Si il y a de la liquidite, la retirer
        if (liquidity > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                })
            );

            // 3. Collecter le principal (tokens de liquidite retires)
            positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        // 4. Reporter les fees au Vault pour distribution aux utilisateurs
        if (fees0 > 0 || fees1 > 0) {
            // Transferer PHYSIQUEMENT les fees au vault
            if (fees0 > 0) {
                IERC20(token0).safeTransfer(vault, fees0);
            }
            if (fees1 > 0) {
                IERC20(token1).safeTransfer(vault, fees1);
            }

            // Enregistrer ET distribuer les fees aux utilisateurs
            IMultiUserVault(vault).recordFeesCollected(fees0, fees1);
        }

        // 5. Burn le NFT
        positionManager.burn(tokenId);

        // 6. Retirer de notre tracking interne
        _removePosition(tokenId);

        // 7. Emettre l'evenement avec les vraies fees collectees
        emit PositionBurned(tokenId, liquidity, uint128(fees0), uint128(fees1));
    }

    // Event pour burnPosition
    event PositionBurned(
        uint256 indexed tokenId,
        uint128 liquidityBurned,
        uint128 fees0Collected,
        uint128 fees1Collected
    );

    /**
     * @notice Execute a swap via Uniswap V3
     * @notice Execute a swap via Uniswap V3 SwapRouter
     * @param tokenIn Source token address
     * @param tokenOut Destination token address
     * @param amountIn Amount to swap
     * @param minAmountOut Minimum output (slippage protection)
     * @return amountOut Actual amount received
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 amountOut)
    {
        require(
            (tokenIn == token0 && tokenOut == token1) ||
            (tokenIn == token1 && tokenOut == token0),
            "E43"
        );
        require(amountIn > 0, "E45");
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "E46");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: config.fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);

        // Optional fee to treasury
        if (swapFeeBps > 0 && treasuryAddress != address(0)) {
            uint256 feeAmount = (amountOut * swapFeeBps) / 10000;
            if (feeAmount > 0) {
                IERC20(tokenOut).safeTransfer(treasuryAddress, feeAmount);
                amountOut -= feeAmount;
            }
        }

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Check if the current position needs rebalancing
    function needsRebalance() external view returns (bool) {
        (,, bool _needsRebalance,,) = RangeOperations.getBotInstructions(
            positionCount,
            config.maxPositions,
            consecutiveFailures,
            MAX_CONSECUTIVE_FAILURES,
            _lastFailureTimestamp,
            FAILURE_COOLDOWN,
            getOwnerPositions(),
            positionManager,
            priceCache
        );
        return _needsRebalance;
    }

    /// @notice Atomic rebalance: burn → swap → mint → pay keeper bounty
    /// @param swapAmountIn Amount to swap (must be ≤ initMultiSwapTvl in USD)
    /// @param minAmountOut Minimum swap output (slippage protection)
    /// @param tokenIn Source token for swap
    /// @param tokenOut Destination token for swap
    function rebalance(
        uint256 swapAmountIn,
        uint256 minAmountOut,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        // Verify rebalance is needed
        (bool hasPosition, uint256 tokenId, bool _needsRebalance,,) = RangeOperations.getBotInstructions(
            positionCount,
            config.maxPositions,
            consecutiveFailures,
            MAX_CONSECUTIVE_FAILURES,
            _lastFailureTimestamp,
            FAILURE_COOLDOWN,
            getOwnerPositions(),
            positionManager,
            priceCache
        );
        require(_needsRebalance, "No rebalance needed");

        // Check swap amount vs initMultiSwapTvl
        if (initMultiSwapTvl > 0) {
            // Estimate USD value using price cache
            uint256 swapValueUSD;
            if (tokenIn == token0) {
                swapValueUSD = (swapAmountIn * priceCache.price0) / (10 ** config.token0Decimals);
            } else {
                swapValueUSD = (swapAmountIn * priceCache.price1) / (10 ** config.token1Decimals);
            }
            require(swapValueUSD <= initMultiSwapTvl * 1e8, "Use multi-step");
        }

        // 1. Lock vault
        IMultiUserVault(vault).startRebalance();

        // 2. Burn existing position if any
        if (hasPosition && tokenId > 0) {
            this.burnPosition(tokenId);
        }

        // 3. Swap if needed
        if (swapAmountIn > 0) {
            require(
                (tokenIn == token0 && tokenOut == token1) ||
                (tokenIn == token1 && tokenOut == token0),
                "E43"
            );
            require(IERC20(tokenIn).balanceOf(address(this)) >= swapAmountIn, "E46");

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: config.fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapAmountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            swapRouter.exactInputSingle(params);
        }

        // 4. Mint new position
        this.mintInitialPosition();

        // 5. Unlock vault
        IMultiUserVault(vault).endRebalance();

        // 6. Pay keeper bounty (try/catch - don't revert if bounty fails)
        if (treasuryAddress != address(0)) {
            try ITreasury(treasuryAddress).payKeeperBounty(msg.sender) {} catch {}
        }
    }

    // ===== ADMIN SETTERS =====

    function setInitMultiSwapTvl(uint256 _initMultiSwapTvl) external onlyAuthorized {
        initMultiSwapTvl = _initMultiSwapTvl;
    }

    function setSwapFeeBps(uint16 _swapFeeBps) external onlyAuthorized {
        require(_swapFeeBps <= 1000, "Max 10%");
        swapFeeBps = _swapFeeBps;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyAuthorized {
        treasuryAddress = _treasuryAddress;
    }

    // ===== EVENTS =====

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

}