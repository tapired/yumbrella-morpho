// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IOracle} from "./interfaces/IOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";
import {Base4626Compounder} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";

interface IKeeper {
    function report(address _strategy) external returns (uint256, uint256);
}

/// @notice You can farm under my Yumbrella
contract Yumbrella is Base4626Compounder {
    using SafeERC20 for ERC20;

    struct WithdrawRequest {
        uint256 shares;
        uint256 timestamp;
    }

    uint256 public constant WAD = 1e18;

    /// @notice The senior vault that will use Yumbrella as its accountant.
    IVault public immutable SENIOR_VAULT;

    /// @notice The auction contract that will be used to sell the rewards.
    address public rewardAuction;

    /// @notice The ratio of the loss to try to refund to the senior vault.
    uint256 public refundRatio;

    /// @notice The accepted ratio of deposits in the senior vault to the amount staked in Yumbrella.
    uint256 public collateralRatio;

    /// @notice The cooldown period after a withdraw request before the user can withdraw.
    uint256 public withdrawCooldown;

    /// @notice The window of time after a withdraw request has cooled down that the withdraw can be processed.
    /// If this window passes without the user calling `withdraw`, the user will need to recall `requestWithdraw`.
    uint256 public withdrawWindow;

    /// @notice The performance fee to charge the senior vault.
    uint256 public seniorVaultPerformanceFee;

    /// @notice The withdraw requests of users.
    mapping(address => WithdrawRequest) public withdrawRequests;

    /// @notice Flag to block interactions until next strategy report sync.
    bool public pendingLossSync;

    constructor(
        address _asset,
        string memory _name,
        address _seniorVault,
        address _assetToSeniorAssetOracle,
        address _yieldVault
    ) Base4626Compounder(_asset, _name, _yieldVault) {
        SENIOR_VAULT = IVault(_seniorVault);
        // VAULT_FACTORY = IVaultFactory(IValtCorrected(_seniorVault).FACTORY());

        // _yieldVault == asset is checked in Base4626Compounder constructor
        require(
            address(asset) == IVault(_seniorVault).asset(),
            "asset mismatch"
        );

        seniorVaultPerformanceFee = 1_000;
        refundRatio = 10_000;
        collateralRatio = 10e18; // 10x
        withdrawCooldown = 7 days;
        withdrawWindow = 7 days;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                    VAULT CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function available_deposit_limit(
        address /* _receiver */
    ) external view returns (uint256) {
        uint256 currentAssets = SENIOR_VAULT.totalAssets();
        uint256 maxAssets = (valueOfVault() * collateralRatio) / WAD;

        return currentAssets >= maxAssets ? 0 : maxAssets - currentAssets;
    }

    // Don't allow withdraws if any of the strategies have unrealised losses.
    function available_withdraw_limit(
        address,
        uint256 /* _maxLoss */,
        address[] calldata _strategies
    ) external view returns (uint256) {
        address[] memory strategies;
        if (SENIOR_VAULT.use_default_queue() || _strategies.length == 0) {
            strategies = SENIOR_VAULT.get_default_queue();
        } else {
            strategies = _strategies;
        }

        // This check is basically ensures that if there is a loss on the senior vault strategies
        // that are reported by "harvestAndReport" on the strategy level but not yet realized on the vault level.
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(strategies[i]).current_debt;
            if (debt > 0) {
                if (
                    SENIOR_VAULT.assess_share_of_unrealised_losses(
                        strategies[i],
                        debt
                    ) !=
                    0 ||
                    // but we also need to check if there are losses on the vaults strategies
                    // that are not reported by "harvestAndReport" on the strategy level.
                    IMorphoLossAwareCompounder(strategies[i]).lossExists()
                ) return 0;
            }
        }

        return type(uint256).max;
    }

    function report(
        address /* _strategy */,
        uint256 _gain,
        uint256 _loss
    ) external returns (uint256 _fees, uint256 _refunds) {
        require(msg.sender == address(SENIOR_VAULT), "only senior vault");

        if (_gain > 0) {
            _fees = (_gain * seniorVaultPerformanceFee) / MAX_BPS;
        } else {
            _refunds = Math.min(
                (_loss * refundRatio) / MAX_BPS,
                valueOfVault()
            );
            uint256 idleSeniorVaultAssetBalance = asset.balanceOf(
                address(this)
            );
            if (_refunds > idleSeniorVaultAssetBalance) {
                _freeFunds(_refunds - idleSeniorVaultAssetBalance);
            }
            asset.forceApprove(address(SENIOR_VAULT), _refunds);
            // Block deposits/withdrawals until keeper performs the next report sync.
            pendingLossSync = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        if (pendingLossSync) return 0;

        WithdrawRequest memory request = withdrawRequests[_owner];
        if (
            // If the cooldown period has passed
            request.timestamp < block.timestamp &&
            // And the window has not passed
            request.timestamp + withdrawWindow > block.timestamp
        ) {
            uint256 requestedAssets = TokenizedStrategy.convertToAssets(
                request.shares
            );
            return
                Math.min(
                    requestedAssets + 1,
                    balanceOfAsset() + vaultsMaxWithdraw() + 1
                );
        }
        return 0;
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (pendingLossSync) return 0;
        return super.availableDepositLimit(_owner);
    }

    // NOTE: This means users continue to earn rewards while unlocked but also can get slashed.
    function requestWithdraw(uint256 _shares) external {
        uint256 currentShares = withdrawRequests[msg.sender].shares;
        _shares = Math.min(
            _shares + currentShares,
            TokenizedStrategy.balanceOf(msg.sender)
        );

        withdrawRequests[msg.sender] = WithdrawRequest({
            shares: _shares,
            timestamp: block.timestamp + withdrawCooldown
        });
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param . The current amount of idle funds that are available to deploy.
     */
    function _tend(uint256 /* _totalIdle */) internal override {
        uint256 _loss;
        bool _lossExistsOnCompounder;
        address[] memory strategies = SENIOR_VAULT.get_default_queue();
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(strategies[i]).current_debt;
            if (debt > 0) {
                if (!_lossExistsOnCompounder) {
                    _lossExistsOnCompounder = IMorphoLossAwareCompounder(
                        strategies[i]
                    ).lossExists();
                }

                _loss += SENIOR_VAULT.assess_share_of_unrealised_losses(
                    strategies[i],
                    debt
                );
            }
        }

        // if there are losses on strategies they need to be reported first.
        if (_loss > 0 && !_lossExistsOnCompounder) {
            // Eat the loss.
            IKeeper(TokenizedStrategy.keeper()).report(address(this));
        }

        // no loss so deposit idle to yield vault
        uint256 idleSeniorVaultAssetBalance = asset.balanceOf(address(this));
        if (idleSeniorVaultAssetBalance > 0) {
            vault.deposit(idleSeniorVaultAssetBalance, address(this));
        }
    }

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        uint256 seniorVaultShares = SENIOR_VAULT.balanceOf(address(this));
        if (seniorVaultShares > 0) {
            SENIOR_VAULT.redeem(
                seniorVaultShares,
                address(this),
                address(this)
            );
        }

        _totalAssets = super._harvestAndReport();
        pendingLossSync = false;
    }

    // just in case if the amount of senior vault shares is not redeemable in harvest
    function manualRedeemSeniorVaultShares(
        uint256 _amount
    ) external onlyManagement {
        if (_amount == type(uint256).max) {
            _amount = SENIOR_VAULT.balanceOf(address(this));
        }
        SENIOR_VAULT.redeem(_amount, address(this), address(this));
    }

    // just in case if the idle amounts needs to be manually deposited to the yield vault
    function manualDepositToYieldVault(
        uint256 _amount
    ) external onlyManagement {
        if (_amount == type(uint256).max) {
            _amount = asset.balanceOf(address(this));
        }
        vault.deposit(_amount, address(this));
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view override returns (bool) {
        address[] memory strategies = SENIOR_VAULT.get_default_queue();
        bool _lossExists;
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(strategies[i]).current_debt;
            if (debt > 0) {
                _lossExists = IMorphoLossAwareCompounder(strategies[i])
                    .lossExists();
                if (_lossExists) {
                    return false;
                }
                if (
                    SENIOR_VAULT.assess_share_of_unrealised_losses(
                        strategies[i],
                        debt
                    ) != 0
                ) {
                    return true;
                }
            }
        }

        if (asset.balanceOf(address(this)) > 0) {
            return true;
        }

        return false;
    }

    /**
     * @dev Set the reward auction address.
     * @param _rewardAuction The address of the reward auction.
     */
    function setRewardAuction(
        address _rewardAuction
    ) external onlyEmergencyAuthorized {
        if (_rewardAuction != address(0)) {
            require(
                Auction(_rewardAuction).want() == address(asset),
                "wrong want"
            );
            require(
                Auction(_rewardAuction).receiver() == address(this),
                "wrong receiver"
            );
        }
        rewardAuction = _rewardAuction;
    }

    function kickAuction(
        address _token
    ) external onlyKeepers returns (uint256) {
        return _kickAuction(_token);
    }

    /**
     * @dev Kick an auction for a given token.
     * @param _from The token that was being sold.
     */
    function _kickAuction(address _from) internal virtual returns (uint256) {
        require(
            _from != address(asset) &&
                _from != address(vault) &&
                _from != address(SENIOR_VAULT),
            "cannot kick"
        );
        uint256 _balance = ERC20(_from).balanceOf(address(this));
        ERC20(_from).safeTransfer(rewardAuction, _balance);
        return Auction(rewardAuction).kick(_from);
    }

    /**
     * @dev Set the performance fee for the multi strategy vault.
     * @param _seniorVaultPerformanceFee The performance fee to charge the senior vault.
     */
    function setSeniorVaultPerformanceFee(
        uint256 _seniorVaultPerformanceFee
    ) external onlyManagement {
        seniorVaultPerformanceFee = _seniorVaultPerformanceFee;
    }

    /**
     * @dev Set the refund ratio.
     * @param _refundRatio The refund ratio.
     */
    function setRefundRatio(uint256 _refundRatio) external onlyManagement {
        refundRatio = _refundRatio;
    }

    /**
     * @dev Set the withdraw cooldown.
     * @param _withdrawCooldown The withdraw cooldown.
     */
    function setWithdrawCooldown(
        uint256 _withdrawCooldown
    ) external onlyManagement {
        require(_withdrawCooldown < 365 days, "too long");
        withdrawCooldown = _withdrawCooldown;
    }

    /**
     * @dev Set the withdraw window.
     * @param _withdrawWindow The withdraw window.
     */
    function setWithdrawWindow(
        uint256 _withdrawWindow
    ) external onlyManagement {
        require(_withdrawWindow > 1 days, "too short");
        withdrawWindow = _withdrawWindow;
    }

    /**
     * @dev Set the collateral ratio.
     * @param _collateralRatio The collateral ratio.
     */
    function setCollateralRatio(
        uint256 _collateralRatio
    ) external onlyManagement {
        collateralRatio = _collateralRatio;
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(Math.min(_amount, vaultsMaxWithdraw()));
    }
}
