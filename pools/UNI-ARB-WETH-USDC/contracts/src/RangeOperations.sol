// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title RangeOperations
 * @notice Library externe pour les operations complexes du RangeManager
 */
library RangeOperations {
    using SafeERC20 for IERC20;

    // ===== STRUCTS (partages) =====
    
    struct RangeConfig {
        uint24 fee;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint16 toleranceBps;
        uint24 maxSlippageBps;
        uint64 lastRebalanceTime;
        bool oraclesConfigured;
        uint16 rangeUpPercent;
        uint16 rangeDownPercent;
        uint32 maxPositions;
    }

    struct PriceCache {
        uint128 price0;
        uint128 price1;
        uint160 poolSqrtPriceX96;
        int24 poolTick;
        uint64 timestamp;
        bool valid;
    }

    struct ProtectionConfig {
        bool sandwichDetectionEnabled;
        bool mevProtectionEnabled;
        bool failureProtectionEnabled;
        uint16 sandwichThresholdBps;
        uint16 maxOracleDeviationBps;
    }

    struct SystemStats {
        uint128 totalRebalances;
        uint128 totalVolume;
        uint64 lastRebalanceBlock;
        uint32 failedOperations;
        uint32 successfulOperations;
        uint32 consecutiveFailures;
        bool initialized;
    }

    struct OptimalSwapParams {
        bool swapNeeded;
        bool zeroForOne;
        uint256 amountIn;
        uint256 currentBalance0;
        uint256 currentBalance1;
        uint256 targetRatio0Bps;
        int24 tickLower;
        int24 tickUpper;
    }

    // ===== FONCTIONS PRINCIPALES =====

    /**
     * @notice Met a jour le cache prix avec validation des oracles
     */
    function updatePriceCache(
        AggregatorV3Interface token0PriceFeed,
        AggregatorV3Interface token1PriceFeed,
        IUniswapV3Pool pool,
        RangeConfig memory
    ) external view returns (PriceCache memory newCache) {
        if (address(token0PriceFeed) == address(0) || address(token1PriceFeed) == address(0)) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }
    
        // Pas de try/catch ici, le contrat principal s'en charge
        (, int256 price0, , uint256 updatedAt0, ) = token0PriceFeed.latestRoundData();
        (, int256 price1, , uint256 updatedAt1, ) = token1PriceFeed.latestRoundData();
        
        if (price0 <= 0 || price1 <= 0) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }
    
        uint256 maxAge = 90000; // 25 heures pour stablecoins
        if (block.timestamp - updatedAt0 > maxAge || block.timestamp - updatedAt1 > maxAge) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }
    
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        
        return PriceCache({
            price0: _safeUint128(uint256(price0)),
            price1: _safeUint128(uint256(price1)),
            poolSqrtPriceX96: sqrtPriceX96,
            poolTick: tick,
            timestamp: uint64(block.timestamp),
            valid: true
        });
    }

    /**
     * @notice Calcule les ticks cibles pour une nouvelle position
     * @dev Supporte les ranges asymetriques via rangeUpPercent et rangeDownPercent
     *      Le ratio optimal de tokens est calcule automatiquement par calculateOptimalRatio()
     */
    function calculateTargetTicks(
        PriceCache memory priceCache,
        RangeConfig memory config,
        IUniswapV3Pool pool
    ) external view returns (int24 tickLower, int24 tickUpper) {
        return _calculateTargetTicksInternal(priceCache, config, pool);
    }

    /**
     * @notice Version interne de calculateTargetTicks (pour appel depuis autres fonctions de la library)
     * @dev Supporte les ranges asymetriques: ticksUp et ticksDown peuvent etre differents
     *      Cela permet d'optimiser la generation de fees selon les conditions de marche
     */
    function _calculateTargetTicksInternal(
        PriceCache memory priceCache,
        RangeConfig memory config,
        IUniswapV3Pool pool
    ) internal view returns (int24 tickLower, int24 tickUpper) {

        int24 currentTick = priceCache.poolTick;
        int24 tickSpacing = pool.tickSpacing();

        // Calculer le nombre de ticks pour chaque cote (ASYMETRIQUE)
        // rangeUpPercent et rangeDownPercent sont en basis points (100 = 1%)
        // 1% de prix ≈ 100 ticks (formule exacte: log(1.01) / log(1.0001) ≈ 99.5)
        int24 ticksUp = int24(uint24(config.rangeUpPercent)) * 100 / 100;
        int24 ticksDown = int24(uint24(config.rangeDownPercent)) * 100 / 100;

        // Arrondir chaque cote au tickSpacing
        int24 spacingsUp = ticksUp / tickSpacing;
        if (spacingsUp < 1) spacingsUp = 1; // Minimum 1 tickSpacing
        int24 spacingsDown = ticksDown / tickSpacing;
        if (spacingsDown < 1) spacingsDown = 1; // Minimum 1 tickSpacing

        int24 alignedTicksUp = spacingsUp * tickSpacing;
        int24 alignedTicksDown = spacingsDown * tickSpacing;

        // Calculer les ticks theoriques ASYMETRIQUES autour du currentTick
        int24 theoreticalLower = currentTick - alignedTicksDown;
        int24 theoreticalUpper = currentTick + alignedTicksUp;

        // Aligner tickLower vers le bas (floor)
        tickLower = _floorToTickSpacing(theoreticalLower, tickSpacing);

        // Aligner tickUpper vers le haut (ceil)
        tickUpper = _ceilToTickSpacing(theoreticalUpper, tickSpacing);

        // Verifier que le currentTick est dans le range
        // Si non, ajuster le range pour le contenir
        if (currentTick <= tickLower) {
            // currentTick trop proche du bas, decaler le range vers le bas
            tickLower = _floorToTickSpacing(currentTick - 1, tickSpacing);
            tickUpper = tickLower + alignedTicksUp + alignedTicksDown;
        } else if (currentTick >= tickUpper) {
            // currentTick trop proche du haut, decaler le range vers le haut
            tickUpper = _ceilToTickSpacing(currentTick + 1, tickSpacing);
            tickLower = tickUpper - alignedTicksUp - alignedTicksDown;
        }

        // Verification finale : s'assurer que le currentTick est bien dans le range
        require(tickLower < currentTick && currentTick < tickUpper, "Current tick not in range");

        _validateTicks(tickLower, tickUpper, currentTick, tickSpacing);
    }
    
    /**
     * @notice Verifie si une position est hors du range
     * @param tokenId ID de la position a verifier
     * @param positionManager Le gestionnaire de positions NFT
     * @param priceCache Cache des prix actuels
     * @return bool True si la position est hors du range
     */
    function isPositionOutOfRange(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    ) external view returns (bool) {
        if (!priceCache.valid) return false;
        
        try positionManager.positions(tokenId) returns (
            uint96,
            address,
            address, 
            address,
            uint24,
            int24 tickLower,
            int24 tickUpper,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        ) {
            int24 currentTick = priceCache.poolTick;
            return currentTick <= tickLower || currentTick >= tickUpper;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Ajoute de la liquidite a une position existante SANS faire de swap
     * @dev Les swaps doivent etre faits AVANT via Velora (multi-swap)
     * @param token0 Adresse du token0
     * @param token1 Adresse du token1
     * @param tokenId ID de la position
     * @param positionManager Le gestionnaire de positions
     * @param contractAddress Adresse du contrat (RangeManager)
     * @return liquidity Liquidite ajoutee
     * @return amount0Added Montant de token0 ajoute
     * @return amount1Added Montant de token1 ajoute
     * @dev SECURITY NOTE: This is a library function called via delegatecall from RangeManager.
     *      Access control is enforced by the calling contract (RangeManager) via onlyAuthorized modifier.
     *      Libraries cannot have their own access control modifiers since they execute in the
     *      caller's context. This function only operates on tokens already held by the contract
     *      and cannot transfer funds to arbitrary addresses - it adds liquidity to existing positions.
     */
    function addLiquidityWithoutSwap(
        address token0,
        address token1,
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        address contractAddress
    ) external returns (
        uint128 liquidity,
        uint256 amount0Added,
        uint256 amount1Added
    ) {
        // Récupérer et valider les balances
        (uint256 balance0, uint256 balance1) = _getBalances(token0, token1, contractAddress);
        require(balance0 > 0 || balance1 > 0, "No funds to add");

        // Approuver et ajouter la liquidité (PAS DE SWAP - fait avant via Velora)
        (uint256 newBalance0, uint256 newBalance1) = _approveAndGetBalances(token0, token1, positionManager, contractAddress);

        return _increaseLiquidity(tokenId, newBalance0, newBalance1, positionManager);
    }

    /**
     * @notice Fournit les instructions pour le bot
     * @param positionCount Nombre de positions actives
     * @param maxPositions Limite max de positions
     * @param consecutiveFailures Nombre d'echecs consecutifs
     * @param maxConsecutiveFailures Limite d'echecs autorises
     * @param lastFailureTimestamp Timestamp du dernier echec
     * @param failureCooldown Duree du cooldown apres echecs
     * @param positions Array des positions existantes
     * @param positionManager Le gestionnaire de positions
     * @param priceCache Cache des prix actuels
     */
    function getBotInstructions(
        uint32 positionCount,
        uint32 maxPositions,
        uint256 consecutiveFailures,
        uint256 maxConsecutiveFailures,
        uint256 lastFailureTimestamp,
        uint256 failureCooldown,
        uint256[] memory positions,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    ) external view returns (
        bool hasPosition,
        uint256 tokenId,
        bool needsRebalance,
        string memory action,
        string memory reason
    ) {
        // Verifier le cooldown
        if (consecutiveFailures >= maxConsecutiveFailures && 
            block.timestamp < lastFailureTimestamp + failureCooldown) {
            return (false, 0, false, "WAIT_COOLDOWN", "Cooldown active");
        }
        
        hasPosition = positions.length > 0;
        
        if (!hasPosition) {
            if (positionCount >= maxPositions) {
                return (false, 0, false, "MAX_POSITIONS_REACHED", "Limit positions");
            }
            return (false, 0, true, "MINT_INITIAL", "No position exists");
        }
        
        // Verifier chaque position
        for (uint i = 0; i < positions.length; i++) {
            if (_isPositionOutOfRange(positions[i], positionManager, priceCache)) {
                return (true, positions[i], true, "REBALANCE", "Position out of Range");
            }
        }
        
        tokenId = positions.length > 0 ? positions[0] : 0;
        action = "WAIT";
        reason = "All positions in Range";
    }
    
    /**
     * @notice Recupere les balances actuelles totales (libres + dans positions)
     */
    function getCurrentBalances(
        address token0,
        address token1,
        address contractAddress,
        uint256[] memory positions,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool
    ) external view returns (uint256 balance0, uint256 balance1) {
        balance0 = IERC20(token0).balanceOf(contractAddress);
        balance1 = IERC20(token1).balanceOf(contractAddress);

        for (uint i = 0; i < positions.length; i++) {
            (uint256 pos0, uint256 pos1) = _getPositionBalance(positions[i], positionManager, pool);
            balance0 += pos0;
            balance1 += pos1;
        }
    }

    /**
     * @notice Cree une nouvelle position Uniswap V3
     * @dev SECURITY NOTE: This is a library function called via delegatecall from RangeManager.
     *      Access control is enforced by the calling contract (RangeManager) via onlyAuthorized modifier.
     *      Libraries cannot have their own access control modifiers since they execute in the
     *      caller's context. This function only uses tokens already held by the contract
     *      and mints a new position with recipient set to contractAddress (the calling contract).
     *
     *      FUND REDIRECTION RISK MITIGATION: The contractAddress parameter MUST be address(this)
     *      from the caller's perspective. In RangeManager._mintInternal(), this function is called
     *      with `address(this)` hardcoded - never from user input. The library requires this parameter
     *      because libraries execute via delegatecall and need the caller's address passed explicitly.
     *      The calling contract (RangeManager) is responsible for always passing address(this).
     */
    function mintNewPosition(
        address token0,
        address token1,
        RangeConfig memory config,
        int24 tickLower,
        int24 tickUpper,
        INonfungiblePositionManager positionManager,
        address contractAddress
    ) external returns (uint256 tokenId, uint128 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(contractAddress);
        uint256 balance1 = IERC20(token1).balanceOf(contractAddress);
        require(balance0 > 0 || balance1 > 0, "No tokens");

        // Reset allowances a zero d'abord
        IERC20(token0).safeApprove(address(positionManager), 0);
        IERC20(token1).safeApprove(address(positionManager), 0);
        
        // Puis set les nouvelles allowances
        IERC20(token0).safeApprove(address(positionManager), balance0);
        IERC20(token1).safeApprove(address(positionManager), balance1);

        INonfungiblePositionManager.MintParams memory mintParams =
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: config.fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: balance0,
                amount1Desired: balance1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: contractAddress,
                deadline: block.timestamp + 300
            });

        (tokenId, liquidity, ,) = positionManager.mint(mintParams);
    }
    
    /**
     * @notice Collecte et retire la liquidite d'une position
     * @dev SECURITY NOTE: This is a library function called via delegatecall from RangeManager.
     *      Access control is enforced by the calling contract (RangeManager) via onlyAuthorized modifier.
     *      Libraries cannot have their own access control modifiers since they execute in the
     *      caller's context. This function only operates on positions owned by the contract
     *      and sends tokens back to contractAddress (the calling contract) - not to arbitrary addresses.
     *
     *      TREASURY COLLECTOR ADDRESS MITIGATION: The contractAddress parameter MUST be address(this)
     *      from the caller's perspective. When called by RangeManager, it passes address(this) hardcoded -
     *      never from user input. The library requires this parameter because libraries execute via
     *      delegatecall and need the caller's address passed explicitly. The calling contract (RangeManager)
     *      is responsible for always passing address(this) to prevent fund redirection attacks.
     */
    function collectAndRemoveLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        INonfungiblePositionManager positionManager,
        address contractAddress
    ) external returns (uint256 totalCollected0, uint256 totalCollected1) {
        // 1. Collecter TOUTES les fees accumules AVANT de retirer la liquidité
        // Cela inclut les fees de trading + tout tokensOwed résiduel
        (uint256 collected0, uint256 collected1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: contractAddress,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Première collecte = fees de trading pures
        totalCollected0 = collected0;
        totalCollected1 = collected1;

        // 2. Retirer la liquidite (met les tokens dans tokensOwed)
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

            // 3. Collecter les tokens de liquidite retires (principal)
            // IMPORTANT: On collecte mais on ne l'ajoute PAS aux "fees" car c'est le principal
            // Le principal reste dans contractAddress pour créer la nouvelle position
            positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: contractAddress,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        // RETOUR: Seulement les FEES de trading (première collecte)
        // Le principal a été collecté mais n'est pas retourné comme "fees"
    }

    /**
     * @notice Calcule la valeur actuelle du portfolio
     */
    function getCurrentPortfolioValue(
        address token0,
        address token1,
        RangeConfig memory config,
        PriceCache memory priceCache,
        address contractAddress
    ) external view returns (uint256) {
        if (!config.oraclesConfigured || !priceCache.valid) return 0;
        
        uint256 balance0 = IERC20(token0).balanceOf(contractAddress);
        uint256 balance1 = IERC20(token1).balanceOf(contractAddress);
        
        if (priceCache.price0 == 0 || priceCache.price1 == 0) return 0;
        
        uint256 value0 = (balance0 * priceCache.price0) / (10 ** config.token0Decimals);
        uint256 value1 = (balance1 * priceCache.price1) / (10 ** config.token1Decimals);
        
        return value0 + value1;
    }
    
    /**
     * @notice Calcule le ratio optimal de tokens pour une position dans un range donne
     * @dev Utilise les formules exactes de Uniswap V3 pour calculer les montants de liquidite
     *      Cela garantit que le swap preparera exactement le bon ratio pour minimiser le dust
     * @return ratio0 Pourcentage de valeur en token0 (en basis points sur 10000)
     */
    function calculateOptimalRatio(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) public pure returns (uint256 ratio0) {
        // Si on est en dessous du range, tout en token0
        if (currentTick <= tickLower) {
            return 10000; // 100%
        }

        // Si on est au-dessus du range, tout en token1
        if (currentTick >= tickUpper) {
            return 0; // 0%
        }

        // Dans le range : calcul precis base sur les formules Uniswap V3
        uint160 sqrtPriceLower = getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpper = getSqrtRatioAtTick(tickUpper);

        // Protection overflows
        require(sqrtPriceX96 > sqrtPriceLower && sqrtPriceX96 < sqrtPriceUpper, "Price out of range");

        // Pour une liquidite L donnee, Uniswap V3 utilise:
        // amount0 = L * (1/sqrtPrice - 1/sqrtPriceUpper)
        // amount1 = L * (sqrtPrice - sqrtPriceLower)
        //
        // Le ratio de VALEUR (pas de quantite) est:
        // value0 = amount0 * price = amount0 * sqrtPrice^2
        // value1 = amount1 * 1 (si token1 = stablecoin)
        //
        // ratio0 = value0 / (value0 + value1)

        // Calcul de amount0 et amount1 pour une liquidite unitaire (L=2^96 pour eviter les divisions)
        // amount0 = L * (sqrtPriceUpper - sqrtPrice) / (sqrtPrice * sqrtPriceUpper)
        // amount1 = L * (sqrtPrice - sqrtPriceLower)

        // Pour eviter les overflows, on travaille avec des ratios
        // amount0_normalized = (sqrtPriceUpper - sqrtPrice) / sqrtPrice  (en Q96)
        // amount1_normalized = (sqrtPrice - sqrtPriceLower)  (en Q96)

        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 sqrtPL = uint256(sqrtPriceLower);
        uint256 sqrtPU = uint256(sqrtPriceUpper);

        // amount0 * sqrtPrice (proportionnel) = (sqrtPU - sqrtP) * 2^96 / sqrtPU
        // Ceci represente la "valeur" de token0 en termes de sqrt
        uint256 amount0Value = ((sqrtPU - sqrtP) << 96) / sqrtPU;

        // amount1 (proportionnel) = sqrtP - sqrtPL
        // Pour convertir en meme unite de valeur, on multiplie par sqrtP
        // car price = sqrtP^2 / 2^192, et on veut value1 = amount1 * 1
        uint256 amount1Value = sqrtP - sqrtPL;

        // Pour avoir le meme denominateur, on multiplie amount0Value par sqrtP
        // value0_total = amount0Value * sqrtP / 2^96
        // value1_total = amount1Value
        //
        // Mais pour eviter overflow, on calcule directement le ratio:
        // ratio0 = value0 / (value0 + value1)
        //        = (amount0Value * sqrtP) / (amount0Value * sqrtP + amount1Value * 2^96)

        uint256 value0Scaled = amount0Value * sqrtP;
        uint256 value1Scaled = amount1Value << 96;

        uint256 totalValue = value0Scaled + value1Scaled;

        if (totalValue == 0) {
            return 5000; // Fallback 50/50 si calcul impossible
        }

        // ratio0 en basis points (10000 = 100%)
        ratio0 = (value0Scaled * 10000) / totalValue;

        // Securite: borner entre 0 et 10000
        if (ratio0 > 10000) ratio0 = 10000;

        return ratio0;
    }
    
    // Remplace TickMath.getSqrtRatioAtTick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, 'T');
    
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
    
        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
    
    // Ajouter les calculs de liquidite
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        require(sqrtRatioAX96 > 0, "sqrtRatioA cannot be 0");
        
        uint256 numerator = uint256(liquidity) << 96; // L * 2^96
        uint256 part1 = numerator / sqrtRatioAX96;
        uint256 part2 = numerator / sqrtRatioBX96;
        
        return part1 - part2;
    }
    
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        return uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96) >> 96;
    }

    // ===== FONCTIONS PRIVEES =====

    /**
     * @notice Helper interne pour vérifier si position hors range
     */
    function _isPositionOutOfRange(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    ) private view returns (bool) {
        if (!priceCache.valid) return false;

        try positionManager.positions(tokenId) returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24 tickLower,
            int24 tickUpper,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        ) {
            int24 currentTick = priceCache.poolTick;
            return currentTick <= tickLower || currentTick >= tickUpper;
        } catch {
            return false;
        }
    }

    /**
     * @notice Helper pour récupérer les balances de deux tokens
     */
    function _getBalances(
        address token0,
        address token1,
        address contractAddress
    ) private view returns (uint256 balance0, uint256 balance1) {
        balance0 = IERC20(token0).balanceOf(contractAddress);
        balance1 = IERC20(token1).balanceOf(contractAddress);
    }

    /**
     * @notice Helper pour approuver et récupérer les nouvelles balances
     */
    function _approveAndGetBalances(
        address token0,
        address token1,
        INonfungiblePositionManager positionManager,
        address contractAddress
    ) private returns (uint256 newBalance0, uint256 newBalance1) {
        newBalance0 = IERC20(token0).balanceOf(contractAddress);
        newBalance1 = IERC20(token1).balanceOf(contractAddress);

        if (newBalance0 > 0) {
            IERC20(token0).safeApprove(address(positionManager), 0);
            IERC20(token0).safeApprove(address(positionManager), newBalance0);
        }
        if (newBalance1 > 0) {
            IERC20(token1).safeApprove(address(positionManager), 0);
            IERC20(token1).safeApprove(address(positionManager), newBalance1);
        }
    }

    /**
     * @notice Helper pour augmenter la liquidité d'une position
     */
    function _increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        INonfungiblePositionManager positionManager
    ) private returns (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
        return positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 300
            })
        );
    }

    /**
     * @notice Helper pour récupérer les balances d'une position
     */
    function _getPositionBalance(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool
    ) private view returns (uint256 balance0, uint256 balance1) {
        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,,,uint128 tokensOwed0, uint128 tokensOwed1) =
            positionManager.positions(tokenId);

        if (liquidity > 0) {
            (balance0, balance1) = _calculateLiquidityAmounts(tickLower, tickUpper, liquidity, pool);
        }

        balance0 += uint256(tokensOwed0);
        balance1 += uint256(tokensOwed1);
    }

    /**
     * @notice Calcule les montants de liquidité pour une position
     */
    function _calculateLiquidityAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        IUniswapV3Pool pool
    ) private view returns (uint256 amount0, uint256 amount1) {
        (, int24 currentTick,,,,,) = pool.slot0();

        if (currentTick < tickLower) {
            uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);
            return (getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity), 0);
        } else if (currentTick >= tickUpper) {
            uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);
            return (0, getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity));
        } else {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);
            return (
                getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioBX96, liquidity),
                getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96, liquidity)
            );
        }
    }

    function _validateTicks(int24 tickLower, int24 tickUpper, int24 currentTick, int24 tickSpacing) private pure {
        require(tickLower < tickUpper, "Invalid tick order");
        require(_isAlignedToTickSpacing(tickLower, tickSpacing) && _isAlignedToTickSpacing(tickUpper, tickSpacing), "Tick spacing misalignment");
        require(tickLower >= -887272 && tickUpper <= 887272, "Tick out of bounds");
        require(tickUpper - tickLower >= int24(int256(tickSpacing) * int256(10)), "Range too narrow");
        require(tickLower >= currentTick - 50000 && tickUpper <= currentTick + 50000, "Range too wide");
    }

    /**
     * @notice Arrondit un tick vers le bas (floor) au multiple de tickSpacing le plus proche
     * @dev Gere correctement les nombres negatifs (ex: -196327 avec spacing 10 -> -196330)
     */
    function _floorToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) {
            return tick;
        }
        // Pour les nombres negatifs, le reste peut etre negatif
        // floor(-196327, 10) devrait donner -196330, pas -196320
        if (tick < 0 && remainder != 0) {
            return tick - remainder - tickSpacing;
        }
        return tick - remainder;
    }

    /**
     * @notice Arrondit un tick vers le haut (ceil) au multiple de tickSpacing le plus proche
     * @dev Gere correctement les nombres negatifs (ex: -196323 avec spacing 10 -> -196320)
     */
    function _ceilToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) {
            return tick;
        }
        // Pour les nombres negatifs, ceil(-196327, 10) devrait donner -196320
        if (tick < 0) {
            return tick - remainder;
        }
        return tick - remainder + tickSpacing;
    }

    /**
     * @notice Verifie si un tick est aligne sur le tickSpacing
     * @dev Gere correctement les nombres negatifs
     */
    function _isAlignedToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (bool) {
        // Pour les nombres negatifs, % peut retourner un resultat negatif
        // Donc on verifie que le reste est 0 (positif ou negatif)
        return tick % tickSpacing == 0;
    }

    function _safeUint128(uint256 value) private pure returns (uint128) {
        require(value <= type(uint128).max, "Overflow uint128");
        return uint128(value);
    }

    // ===== HELPERS MULTI-USER =====
    
    /**
     * @notice Calcule la liquidite necessaire pour un retrait partiel
     */
    function calculateLiquidityForWithdrawal(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint128 totalLiquidity,
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool
    ) internal view returns (uint128 liquidityNeeded) {
        // Utiliser la fonction existante
        (uint256 amount0Current, uint256 amount1Current) = getPositionAmounts(
            tokenId,
            positionManager,
            pool
        );
        
        // Si pas de liquidite
        if (amount0Current == 0 && amount1Current == 0) return 0;
        
        // Calculer le ratio necessaire
        uint256 ratio0 = amount0Current > 0 ? (amount0Desired * 1e18) / amount0Current : 0;
        uint256 ratio1 = amount1Current > 0 ? (amount1Desired * 1e18) / amount1Current : 0;
        
        uint256 ratio = ratio0 > ratio1 ? ratio0 : ratio1;
        if (ratio > 1e18) ratio = 1e18;
        
        liquidityNeeded = uint128((uint256(totalLiquidity) * ratio) / 1e18);
    }
    
    /**
     * @notice Calcule les montants exacts de token0 et token1 dans une position
     */
    function getPositionAmounts(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = positionManager.positions(tokenId);

        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);

        if (currentTick < tickLower) {
            return (getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity), 0);
        } else if (currentTick >= tickUpper) {
            return (0, getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity));
        } else {
            return (
                getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioBX96, liquidity),
                getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96, liquidity)
            );
        }
    }
    
    /**
     * @notice Recupere les fees non collectees d'une position
     * @param tokenId L'ID de la position NFT
     * @param positionManager Le contrat NFT position manager
     * @return tokensOwed0 Montant de fees en token0
     * @return tokensOwed1 Montant de fees en token1
     */
    function getUnclaimedFees(
        uint256 tokenId,
        INonfungiblePositionManager positionManager
    ) internal view returns (uint128 tokensOwed0, uint128 tokensOwed1) {
        (
            ,,,,,,,,,,
            tokensOwed0,
            tokensOwed1
        ) = positionManager.positions(tokenId);
        
        return (tokensOwed0, tokensOwed1);
    }

    /**
     * @notice Calcule les parametres optimaux pour un swap avant mint/rebalance
     * @param balance0 Balance actuelle de token0
     * @param balance1 Balance actuelle de token1
     * @param priceCache Cache des prix actuels
     * @param config Configuration du range
     * @param pool Pool Uniswap V3
     * @return params Parametres de swap optimaux
     */
    function calculateOptimalSwapParams(
        uint256 balance0,
        uint256 balance1,
        PriceCache memory priceCache,
        RangeConfig memory config,
        IUniswapV3Pool pool
    ) external view returns (OptimalSwapParams memory params) {
        params.currentBalance0 = balance0;
        params.currentBalance1 = balance1;

        if (balance0 == 0 && balance1 == 0) {
            params.targetRatio0Bps = 5000;
            return params;
        }

        // IMPORTANT: Utiliser EXACTEMENT la meme logique que calculateTargetTicks
        // pour que le ratio calcule corresponde au range qui sera effectivement utilise
        (params.tickLower, params.tickUpper) = _calculateTargetTicksInternal(priceCache, config, pool);

        // Calculer le ratio optimal
        params.targetRatio0Bps = calculateOptimalRatio(
            params.tickLower,
            params.tickUpper,
            priceCache.poolTick,
            priceCache.poolSqrtPriceX96
        );

        // Calculer le swap necessaire
        _calculateSwapAmount(params, priceCache, config);

        return params;
    }

    /**
     * @notice Helper interne pour calculer le montant de swap
     * @dev Utilise les prix Chainlink pour calculer la valeur USD (coherence avec le reste du systeme)
     *      Le ratio optimal est calcule via calculateOptimalRatio qui utilise sqrtPriceX96
     */
    function _calculateSwapAmount(
        OptimalSwapParams memory params,
        PriceCache memory priceCache,
        RangeConfig memory config
    ) private pure {
        // Calculer les valeurs en USD via les prix Chainlink (8 decimales)
        // value0_usd = balance0 * price0 / 10^token0Decimals (resultat en 8 decimales)
        // value1_usd = balance1 * price1 / 10^token1Decimals (resultat en 8 decimales)
        uint256 value0 = (params.currentBalance0 * priceCache.price0) / (10 ** config.token0Decimals);
        uint256 value1 = (params.currentBalance1 * priceCache.price1) / (10 ** config.token1Decimals);
        uint256 totalValue = value0 + value1;

        if (totalValue == 0) return;

        // Ratio actuel de token0 en bps
        uint256 currentRatio0Bps = (value0 * 10000) / totalValue;

        // Tolerance: on veut etre TRES precis pour minimiser le dust
        // Utiliser une tolerance tres faible (0.1% = 10 bps minimum)
        uint256 tolerance = config.toleranceBps / 10;
        if (tolerance < 10) tolerance = 10;

        if (currentRatio0Bps > params.targetRatio0Bps + tolerance) {
            // Trop de token0, swap token0 -> token1
            params.zeroForOne = true;

            // Calculer la valeur USD a swapper
            // excessValue = (currentRatio - targetRatio) * totalValue / 10000
            uint256 excessValueUSD = ((currentRatio0Bps - params.targetRatio0Bps) * totalValue) / 10000;

            // Convertir en montant de token0
            // amount0 = excessValueUSD * 10^token0Decimals / price0
            params.amountIn = (excessValueUSD * (10 ** config.token0Decimals)) / priceCache.price0;

            params.swapNeeded = params.amountIn > 0;
            if (params.amountIn > params.currentBalance0) {
                params.amountIn = params.currentBalance0;
            }
        } else if (currentRatio0Bps + tolerance < params.targetRatio0Bps) {
            // Pas assez de token0, swap token1 -> token0
            params.zeroForOne = false;

            // Calculer la valeur USD manquante
            uint256 deficitValueUSD = ((params.targetRatio0Bps - currentRatio0Bps) * totalValue) / 10000;

            // Convertir en montant de token1
            // amount1 = deficitValueUSD * 10^token1Decimals / price1
            params.amountIn = (deficitValueUSD * (10 ** config.token1Decimals)) / priceCache.price1;

            params.swapNeeded = params.amountIn > 0;
            if (params.amountIn > params.currentBalance1) {
                params.amountIn = params.currentBalance1;
            }
        }
    }

}