// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IGmxReader {
    struct PositionProps {
        PositionAddresses addresses;
        PositionNumbers numbers;
        PositionFlags flags;
    }

    struct PositionAddresses {
        address account;
        address market;
        address collateralToken;
    }

    struct PositionNumbers {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        uint256 collateralAmount;
        int256 pendingImpactAmount;
        uint256 borrowingFactor;
        uint256 fundingFeeAmountPerSize;
        uint256 longTokenClaimableFundingAmountPerSize;
        uint256 shortTokenClaimableFundingAmountPerSize;
        uint256 increasedAtTime;
        uint256 decreasedAtTime;
    }

    struct PositionFlags {
        bool isLong;
    }

    struct MarketProps {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }

    struct MarketPrices {
        PriceProps indexTokenPrice;
        PriceProps longTokenPrice;
        PriceProps shortTokenPrice;
    }

    struct PriceProps {
        uint256 min;
        uint256 max;
    }

    function getPosition(
        address dataStore,
        bytes32 key
    ) external view returns (PositionProps memory);

    function getMarket(
        address dataStore,
        address marketAddress
    ) external view returns (MarketProps memory);

    function getMarketTokenPrice(
        address dataStore,
        MarketProps memory market,
        PriceProps memory indexTokenPrice,
        PriceProps memory longTokenPrice,
        PriceProps memory shortTokenPrice,
        bytes32 pnlFactorType,
        bool maximize
    ) external view returns (int256, MarketPoolValueInfoProps memory);

    struct MarketPoolValueInfoProps {
        int256 poolValue;
        int256 longPnl;
        int256 shortPnl;
        int256 netPnl;
        uint256 longTokenAmount;
        uint256 shortTokenAmount;
        uint256 longTokenUsd;
        uint256 shortTokenUsd;
        uint256 totalBorrowingFees;
        uint256 borrowingFeePoolFactor;
        uint256 impactPoolAmount;
    }
}
