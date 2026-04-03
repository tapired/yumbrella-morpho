// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {Setup, ERC20, IYumbrella, IVault} from "./utils/Setup.sol";

interface IYumbrellaDebug is IYumbrella {
    function vaultsMaxWithdraw() external view returns (uint256);
    function valueOfVault() external view returns (uint256);
}

interface IMorphoOracle {
    function price() external view returns (uint256);
}

interface IMetaMorphoVault {
    function lostAssets() external view returns (uint256);
}

interface IMorphoBlue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256);

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function position(
        bytes32 id,
        address user
    )
        external
        view
        returns (
            uint256 supplyShares,
            uint256 borrowShares,
            uint256 collateral
        );

    function market(
        bytes32 id
    )
        external
        view
        returns (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares,
            uint256 lastUpdate,
            uint256 fee
        );
}

contract YumbrellaTest is Setup {
    address public tapir = address(69);
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    bytes32 internal constant LIQUIDATE_EVENT_SIG =
        keccak256(
            "Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)"
        );

    IMorphoBlue.MarketParams public marketParams;
    IMorphoBlue public morphoBlue;

    function _marketId() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    marketParams.loanToken,
                    marketParams.collateralToken,
                    marketParams.oracle,
                    marketParams.irm,
                    marketParams.lltv
                )
            );
    }

    function _liquidationIncentiveFactor() internal view returns (uint256) {
        uint256 factor = (WAD * WAD) /
            (WAD - ((LIQUIDATION_CURSOR * (WAD - marketParams.lltv)) / WAD));
        return
            factor > MAX_LIQUIDATION_INCENTIVE_FACTOR
                ? MAX_LIQUIDATION_INCENTIVE_FACTOR
                : factor;
    }

    function _debtSharesFromCollateral(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal view returns (uint256) {
        uint256 seizedAssetsQuoted = (collateralAmount *
            collateralPrice +
            ORACLE_PRICE_SCALE -
            1) / ORACLE_PRICE_SCALE;
        uint256 debtAssets = (seizedAssetsQuoted *
            WAD +
            _liquidationIncentiveFactor() -
            1) / _liquidationIncentiveFactor();

        // Same as Morpho's SharesMathLib.toSharesUp with virtual shares/assets.
        return
            (debtAssets *
                (totalBorrowShares + VIRTUAL_SHARES) +
                (totalBorrowAssets + VIRTUAL_ASSETS) -
                1) / (totalBorrowAssets + VIRTUAL_ASSETS);
    }

    function _seizedAssetsFromRepaidShares(
        uint256 repaidShares,
        uint256 collateralPrice,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal view returns (uint256) {
        // Morpho's toAssetsDown with virtuals.
        uint256 repaidAssets = (repaidShares *
            (totalBorrowAssets + VIRTUAL_ASSETS)) /
            (totalBorrowShares + VIRTUAL_SHARES);
        // Morpho's repaidShares branch:
        // seized = toAssetsDown(...).wMulDown(lif).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice)
        uint256 withIncentive = (repaidAssets * _liquidationIncentiveFactor()) /
            WAD;
        return (withIncentive * ORACLE_PRICE_SCALE) / collateralPrice;
    }

    function _maxSafeRepaidShares(
        uint256 targetShares,
        uint256 borrowerCollateral,
        uint256 collateralPrice,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = targetShares;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            uint256 seized = _seizedAssetsFromRepaidShares(
                mid,
                collateralPrice,
                totalBorrowAssets,
                totalBorrowShares
            );
            if (seized <= borrowerCollateral) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function _mockOraclePriceBps(
        uint256 _oraclePriceBps
    ) internal returns (uint256 fakePrice) {
        _oraclePriceBps = bound(_oraclePriceBps, 1, MAX_BPS);
        uint256 price = IMorphoOracle(marketParams.oracle).price();
        fakePrice = (price * _oraclePriceBps) / MAX_BPS;
        vm.mockCall(
            marketParams.oracle,
            abi.encodeWithSignature("price()"),
            abi.encode(fakePrice)
        );
    }

    function _printAndAssertBadDebtFromLogs(
        bytes32 id,
        address borrower
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 badDebtAssets;
        uint256 badDebtShares;

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(morphoBlue) &&
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == LIQUIDATE_EVENT_SIG &&
                logs[i].topics.length > 3 &&
                logs[i].topics[1] == id &&
                logs[i].topics[3] == bytes32(uint256(uint160(borrower)))
            ) {
                (, , , badDebtAssets, badDebtShares) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, uint256, uint256, uint256)
                );
                found = true;
            }
        }

        require(found, "Liquidate event not found");
        console2.log("badDebtAssets", badDebtAssets);
        console2.log("badDebtShares", badDebtShares);
        assertGt(badDebtAssets, 0, "badDebtAssets is zero");
        assertGt(badDebtShares, 0, "badDebtShares is zero");
    }

    function _finalizeBadDebt(
        bytes32 id,
        address _user,
        address _borrower
    ) internal {
        (
            ,
            uint256 remainingBorrowShares,
            uint256 remainingCollateral
        ) = morphoBlue.position(id, _borrower);
        if (remainingCollateral > 0 && remainingBorrowShares > 0) {
            vm.recordLogs();
            vm.prank(_user);
            morphoBlue.liquidate(
                marketParams,
                _borrower,
                remainingCollateral,
                0,
                ""
            );
            _printAndAssertBadDebtFromLogs(id, _borrower);
        }
    }

    function setUp() public virtual override {
        super.setUp();

        morphoBlue = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        marketParams
            .collateralToken = 0x88887bE419578051FF9F4eb6C858A951921D8888; // stcUSD
        marketParams.loanToken = address(seniorVaultAsset);
        marketParams.oracle = 0x8E3386B2f6084eB1B0988070c3d826995BD175c0;
        marketParams.irm = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
        marketParams.lltv = 915000000000000000;


    }

    function lendToMorphoBlue(
        address _user,
        uint256 _amount,
        ERC20 _asset
    ) public {
        airdrop(_asset, _user, _amount);

        vm.prank(_user);
        ERC20(_asset).approve(address(morphoBlue), _amount);

        vm.prank(_user);
        morphoBlue.supply(marketParams, _amount, 0, _user, "");
    }

    function borrowFromMorphoBlue(
        address _user,
        uint256 _amount,
        address _asset
    ) public {
        vm.prank(_user);
        morphoBlue.borrow(marketParams, _amount, 0, _user, _user);
    }

    function collateralToMorphoBlue(
        address _user,
        uint256 _amount,
        ERC20 _asset
    ) public {
        airdrop(_asset, _user, _amount);

        vm.prank(_user);
        ERC20(_asset).approve(address(morphoBlue), _amount);

        vm.prank(_user);
        morphoBlue.supplyCollateral(marketParams, _amount, _user, "");
    }

    function makeBadDebt(
        address _user,
        address _borrower,
        uint256 _amountSeized,
        ERC20 _borrowAsset,
        uint256 _oraclePriceBps
    ) public {
        airdrop(_borrowAsset, _user, type(uint128).max);

        vm.prank(_user);
        _borrowAsset.approve(address(morphoBlue), type(uint128).max);

        uint256 fakePrice = _mockOraclePriceBps(_oraclePriceBps);

        bytes32 id = _marketId();
        (
            ,
            uint256 borrowerBorrowShares,
            uint256 borrowerCollateral
        ) = morphoBlue.position(id, _borrower);
        (
            ,
            ,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares,
            ,

        ) = morphoBlue.market(id);

        uint256 collateralAmount = _amountSeized;
        if (collateralAmount > borrowerCollateral)
            collateralAmount = borrowerCollateral;

        uint256 targetShares = _debtSharesFromCollateral(
            collateralAmount,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares
        );
        if (targetShares > borrowerBorrowShares)
            targetShares = borrowerBorrowShares;
        uint256 debtSharesToRepay = _maxSafeRepaidShares(
            targetShares,
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares
        );
        require(debtSharesToRepay > 0, "no safe repay shares");

        vm.prank(_user);
        morphoBlue.liquidate(marketParams, _borrower, 0, debtSharesToRepay, "");

        // If collateral dust remains, do one final collateral-seizing liquidation
        // so Morpho can enter the bad debt branch (collateral == 0).
        _finalizeBadDebt(id, _user, _borrower);
    }

    function simulateBadDebt(
        address _user,
        address _borrower,
        uint256 _amount,
        uint256 _oraclePriceBps
    ) public {
        // make sure there is enough liquidity
        lendToMorphoBlue(_user, _amount, ERC20(marketParams.loanToken));

        uint256 supplyAmount = (11 * _amount) / 10;
        uint256 collateralDecimals = ERC20(marketParams.collateralToken)
            .decimals();
        uint256 loanDecimals = ERC20(marketParams.loanToken).decimals();
        if (collateralDecimals > loanDecimals) {
            supplyAmount =
                supplyAmount *
                10 ** (collateralDecimals - loanDecimals);
        } else {
            supplyAmount =
                supplyAmount /
                10 ** (loanDecimals - collateralDecimals);
        }
        collateralToMorphoBlue(
            _user,
            supplyAmount,
            ERC20(marketParams.collateralToken)
        );

        uint256 borrowAmount = _amount;
        borrowFromMorphoBlue(_borrower, borrowAmount, marketParams.loanToken);

        makeBadDebt(
            _user,
            _borrower,
            supplyAmount,
            ERC20(marketParams.loanToken),
            _oraclePriceBps
        );
    }

    function test_profits(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);
        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Deposit into senior vault
        mintAndDepositIntoSeniorVault(seniorVault, user, _amount);
        assertEq(
            seniorVault.totalAssets(),
            _amount,
            "!seniorVault totalAssets"
        );

        skip(2 days); // simulate interest earnings

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper
            .reportMorphoLossAwareCompounder(
                address(morphoLossAwareCompounder)
            );
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        console2.log("profit", profit);

        skip(morphoLossAwareCompounder.profitMaxUnlockTime());

        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportSeniorVault(
            address(morphoLossAwareCompounder)
        );
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        console2.log("profit", profit);

        assertTrue(
            seniorVault.balanceOf(address(yumbrella)) != 0,
            "!balance of yumbrella"
        );

        console2.log(
            "seniorVault shares for yumbrella",
            seniorVault.balanceOf(address(yumbrella))
        );
    }

    function test_lossCompensation(uint _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);
        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Deposit into senior vault
        mintAndDepositIntoSeniorVault(seniorVault, user, _amount);
        assertEq(
            seniorVault.totalAssets(),
            _amount,
            "!seniorVault totalAssets"
        );

        uint256 oraclePriceBps = 2_000; // 20% of current oracle price
        simulateBadDebt(tapir, tapir, _amount, oraclePriceBps);

        console2.log(
            "loss exists on morpho loss aware compounder",
            morphoLossAwareCompounder.lossExists()
        );

        // Now there are losses on the senior vault let's make sure we can't withdraw from senior vault.
        // gotta do that move to realize lossses...
        vm.prank(tapir);
        IVault(address(morphoLossAwareCompounder.vault())).deposit(0, tapir);
        console2.log(
            "loss exists on morpho loss aware compounder",
            morphoLossAwareCompounder.lossExists()
        );
        vm.expectRevert("exceed withdraw limit");
        vm.prank(user);
        seniorVault.redeem(_amount, user, user);

        // now report on the morpho loss aware compounder make sure loss there.
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper
            .reportMorphoLossAwareCompounder(
                address(morphoLossAwareCompounder)
            );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
        console2.log("loss on morpho loss aware compounder", loss);

        // still can't withdraw from senior vault because vault level losses are not reported yet.
        vm.expectRevert("exceed withdraw limit");
        vm.prank(user);
        seniorVault.redeem(_amount, user, user);

        // now report on senior vault
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportSeniorVault(
            address(morphoLossAwareCompounder)
        );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
        console2.log("loss on senior vault", loss);

        // before the report on yumbrella no body can deposit to yumbrella
        vm.expectRevert("ERC4626: deposit more than max");
        vm.prank(user);
        yumbrella.deposit(_amount, user);

        // before the report on yumbrella no body can withdraw from the yumbrella
        vm.expectRevert("ERC4626: redeem more than max");
        vm.prank(user);
        yumbrella.redeem(_amount, user, user);

        // report on yumbrella make sure there are losses on the yumbrella
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
        console2.log("loss on yumbrella", loss);

        // morpho loss aware compounder beart the losses
        assertLe(
            morphoLossAwareCompounder.pricePerShare(),
            10 ** ERC20(seniorVaultAsset).decimals(),
            "!pps"
        );
        assertGe(
            seniorVault.pricePerShare(),
            10 ** ERC20(seniorVaultAsset).decimals(),
            "!pps"
        );
        // yumbrella pps decreased
        assertLe(yumbrella.pricePerShare(), 10 ** asset.decimals(), "!pps");
        // assertApproxEqAbs(
        //     yumbrella.pricePerShare(),
        //     morphoLossAwareCompounder.pricePerShare(),
        //     2,
        //     "!pps"
        // );

        console2.log(
            "pps of morphoLossAwareCompounder",
            morphoLossAwareCompounder.pricePerShare()
        );
        console2.log("pps of seniorVault", seniorVault.pricePerShare());
        console2.log("pps of yumbrella", yumbrella.pricePerShare());
    }

    function test_afterLoss() public {
        uint256 _amount = 10_000_000e6;
        uint256 _otherAmount = 1_000_000e6;

        // vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);
        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Deposit into senior vault
        mintAndDepositIntoSeniorVault(seniorVault, user, _amount);
        assertEq(
            seniorVault.totalAssets(),
            _amount,
            "!seniorVault totalAssets"
        );

        uint256 oraclePriceBps = 4_000; // 40% of current oracle price
        simulateBadDebt(tapir, tapir, _amount, oraclePriceBps);

        // now report on the morpho loss aware compounder make sure loss there.
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper
            .reportMorphoLossAwareCompounder(
                address(morphoLossAwareCompounder)
            );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");

        // now report on senior vault
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportSeniorVault(
            address(morphoLossAwareCompounder)
        );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");

        // now repor ton yumbrella
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");

        // get the ppses
        uint256 morphoPps = morphoLossAwareCompounder.pricePerShare();
        uint256 seniorPps = seniorVault.pricePerShare();
        uint256 yumbrellaPps = yumbrella.pricePerShare();

        uint256 beforeShares = yumbrella.balanceOf(user);
        mintAndDepositIntoYumbrella(yumbrella, user, _otherAmount);
        uint256 sharesReceived = yumbrella.balanceOf(user) - beforeShares;
        // because pps is decreased!
        assertGe(sharesReceived, _otherAmount, "!shares received");
        console2.log("sharesReceived", sharesReceived);

        // now let's make some profits
        skip(86400 * 5);
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportMorphoLossAwareCompounder(
            address(morphoLossAwareCompounder)
        );
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        console2.log("morpho loss aware compounder profit", profit);

        skip(morphoLossAwareCompounder.profitMaxUnlockTime());
        assertGe(morphoLossAwareCompounder.pricePerShare(), morphoPps, "!pps");

        // report on senior vault
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportSeniorVault(
            address(morphoLossAwareCompounder)
        );
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        console2.log("senior vault profit", profit);

        skip(morphoLossAwareCompounder.profitMaxUnlockTime());
        assertGe(seniorVault.pricePerShare(), seniorPps, "!pps");
        console2.log("senior vault pps", seniorVault.pricePerShare());

        // report on yumbrella
        vm.prank(keeper);
        (profit, loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        console2.log("yumbrella profit", profit);
        assertGe(yumbrella.pricePerShare(), yumbrellaPps, "!pps");

        skip(yumbrella.profitMaxUnlockTime());
        assertGe(yumbrella.pricePerShare(), yumbrellaPps, "!pps");
        console2.log("yumbrella pps", yumbrella.pricePerShare());
    }
}
