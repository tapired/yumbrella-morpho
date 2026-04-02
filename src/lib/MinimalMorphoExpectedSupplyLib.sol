// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

interface IIrmLike {
    function borrowRateView(
        MarketParams memory marketParams,
        Market memory market
    ) external view returns (uint256);
}

interface IMorphoLike {
    function idToMarketParams(
        bytes32 id
    ) external view returns (MarketParams memory);
    function market(bytes32 id) external view returns (Market memory);
    function position(
        bytes32 id,
        address user
    ) external view returns (Position memory);
}

library MinimalMorphoExpectedSupplyLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function expectedSupplyAssets(
        IMorphoLike morpho,
        MarketParams memory marketParams,
        address user
    ) internal view returns (uint256) {
        bytes32 id = marketId(marketParams);
        uint256 shares = morpho.position(id, user).supplyShares;
        (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares
        ) = expectedMarketBalances(morpho, marketParams);
        return toAssetsDown(shares, totalSupplyAssets, totalSupplyShares);
    }

    function expectedMarketBalances(
        IMorphoLike morpho,
        MarketParams memory marketParams
    )
        internal
        view
        returns (uint256 totalSupplyAssets, uint256 totalSupplyShares)
    {
        bytes32 id = marketId(marketParams);
        Market memory market_ = morpho.market(id);

        totalSupplyAssets = uint256(market_.totalSupplyAssets);
        totalSupplyShares = uint256(market_.totalSupplyShares);
        uint256 totalBorrowAssets = uint256(market_.totalBorrowAssets);

        uint256 elapsed = block.timestamp - uint256(market_.lastUpdate);

        if (
            elapsed != 0 &&
            totalBorrowAssets != 0 &&
            marketParams.irm != address(0)
        ) {
            uint256 borrowRate = IIrmLike(marketParams.irm).borrowRateView(
                marketParams,
                market_
            );
            uint256 interest = wMulDown(
                totalBorrowAssets,
                wTaylorCompounded(borrowRate, elapsed)
            );

            totalSupplyAssets += interest;

            if (market_.fee != 0) {
                uint256 feeAmount = wMulDown(interest, uint256(market_.fee));
                uint256 feeShares = toSharesDown(
                    feeAmount,
                    totalSupplyAssets - feeAmount,
                    totalSupplyShares
                );
                totalSupplyShares += feeShares;
            }
        }
    }

    function marketId(
        MarketParams memory marketParams
    ) internal pure returns (bytes32 id) {
        assembly ("memory-safe") {
            id := keccak256(marketParams, 160)
        }
    }

    function toAssetsDown(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return
            mulDivDown(
                shares,
                totalAssets + VIRTUAL_ASSETS,
                totalShares + VIRTUAL_SHARES
            );
    }

    function toSharesDown(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return
            mulDivDown(
                assets,
                totalShares + VIRTUAL_SHARES,
                totalAssets + VIRTUAL_ASSETS
            );
    }

    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function wTaylorCompounded(
        uint256 x,
        uint256 n
    ) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }

    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256) {
        return (x * y) / d;
    }
}
