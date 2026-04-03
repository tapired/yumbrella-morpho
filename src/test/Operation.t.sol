// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IYumbrella} from "./utils/Setup.sol";

interface IYumbrellaDebug is IYumbrella {
    function vaultsMaxWithdraw() external view returns (uint256);
    function valueOfVault() external view returns (uint256);
}

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(yumbrella));
        if (yieldVault == address(0)) assertTrue(yumbrella.vault() == address(morphoLossAwareCompounder), "!vault mismatch");
        assertTrue(address(0) != address(yumbrella));
        assertEq(yumbrella.asset(), address(asset));
        assertEq(yumbrella.management(), management);
        assertEq(yumbrella.performanceFeeRecipient(), performanceFeeRecipient);
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);

        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        vm.prank(user);
        yumbrella.requestWithdraw(_amount);
        skip(yumbrella.withdrawCooldown() + 2);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        yumbrella.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS / 100)
        );

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);

        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(yumbrella), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        vm.prank(user);
        yumbrella.requestWithdraw(_amount);
        skip(yumbrella.withdrawCooldown() + 2);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        yumbrella.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS / 100)
        );

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoYumbrella(yumbrella, user, _amount);

        assertEq(yumbrella.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(yumbrella), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = yumbrellaKeeper.reportYumbrella(
            address(morphoLossAwareCompounder)
        );

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        vm.prank(user);
        yumbrella.requestWithdraw(_amount);
        skip(yumbrella.withdrawCooldown() + 2);

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(yumbrella.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        yumbrella.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        yumbrella.requestWithdraw(expectedShares);
        skip(yumbrella.withdrawCooldown() + 2);
        vm.prank(performanceFeeRecipient);
        yumbrella.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkYumbrellaTotals(yumbrella, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }
    // NOTE: Will be tested more comprehensively in other files with full setup.
    // function test_tendTrigger(uint256 _amount) public {
    //     vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

    //     (bool trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);

    //     // Deposit into strategy
    //     mintAndDepositIntoYumbrella(yumbrella, user, _amount);

    //     (trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);

    //     // Skip some time
    //     skip(1 days);

    //     (trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);

    //     vm.prank(keeper);
    //     yumbrellaKeeper.reportYumbrella(address(morphoLossAwareCompounder));

    //     (trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);

    //     // Unlock Profits
    //     skip(yumbrella.profitMaxUnlockTime());

    //     (trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);

    //     vm.prank(user);
    //     yumbrella.requestWithdraw(_amount);
    //     skip(yumbrella.withdrawCooldown() + 2);

    //     vm.prank(user);
    //     yumbrella.redeem(_amount, user, user);

    //     (trigger, ) = yumbrella.tendTrigger();
    //     assertTrue(!trigger);
    // }
}
