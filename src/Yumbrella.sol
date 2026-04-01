// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IOracle} from "./interfaces/IOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {TokenizedStaker, ERC20, SafeERC20} from "@periphery/Bases/Staker/TokenizedStaker.sol";
import {Auction} from "@periphery/Auctions/Auction.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";

interface IValtCorrected {
    function FACTORY() external view returns (address);
}

interface IKeeper {
    function report(address _strategy) external returns (uint256, uint256);
}

/// @notice You can farm under my Yumbrella
contract Yumbrella is TokenizedStaker {
    using SafeERC20 for ERC20;

    struct WithdrawRequest {
        uint256 shares;
        uint256 timestamp;
    }

    uint256 public constant WAD = 1e18;

    /// @notice The senior vault that will use Yumbrella as its accountant.
    IVault public immutable SENIOR_VAULT;
    IStrategy public immutable vault; // yield vault

    /// @notice The underlying asset of the senior vault.
    ERC20 public immutable SENIOR_ASSET;

    /// @notice The V3 vault factory that the senior vault belongs to.
    IVaultFactory internal immutable VAULT_FACTORY =
        IVaultFactory(0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F);

    /// @notice The auction contract that will be used to sell the token for losses.
    address public auction;

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

    /// @notice The oracle that will be used to convert the underlying asset to the senior asset.
    IOracle public assetToSeniorAssetOracle;

    /// @notice The withdraw requests of users.
    mapping(address => WithdrawRequest) public withdrawRequests;

    constructor(
        address _asset,
        string memory _name,
        address _seniorVault,
        address _assetToSeniorAssetOracle,
        address _yieldVault
    ) TokenizedStaker(_asset, _name) {
        SENIOR_VAULT = IVault(_seniorVault);
        require(IStrategy(_yieldVault).asset() == _asset, "wrong vault");
        vault = IStrategy(_yieldVault);
        SENIOR_ASSET = ERC20(SENIOR_VAULT.asset());
        // VAULT_FACTORY = IVaultFactory(IValtCorrected(_seniorVault).FACTORY());
        assetToSeniorAssetOracle = IOracle(_assetToSeniorAssetOracle);
        asset.safeApprove(_yieldVault, type(uint256).max);

        seniorVaultPerformanceFee = 1_000;
        refundRatio = 10_000;
        collateralRatio = 10e18; // 10x
        withdrawCooldown = 7 days;
        withdrawWindow = 7 days;

        _addReward(_seniorVault, msg.sender, 1 weeks);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal override {
        vault.deposit(_amount, address(this));
        _stake();
    }

    function _freeFunds(uint256 _amount) internal override {
        uint256 shares = vault.previewWithdraw(_amount);
        uint256 vaultBalance = balanceOfVault();
        if (shares > vaultBalance) {
            unchecked {
                _unStake(shares - vaultBalance);
            }
            shares = Math.min(shares, balanceOfVault());
        }

        vault.redeem(shares, address(this), address(this));
    }

    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) internal virtual override {
        // Fully reset the withdraw request.
        delete withdrawRequests[owner];
        super._postWithdrawHook(assets, shares, receiver, owner, maxLoss);
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function available_deposit_limit(
        address /* _receiver */
    ) external view returns (uint256) {
        uint256 currentAssets = SENIOR_VAULT.totalAssets();
        uint256 maxAssets = (_fromAssetToSeniorAsset(valueOfVault()) *
            collateralRatio) / WAD;

        return currentAssets >= maxAssets ? 0 : maxAssets - currentAssets;
    }

    // Don't allow withdraws if any of the strategies have unrealised losses.
    function available_withdraw_limit(
        address _owner,
        uint256 /* _maxLoss */,
        address[] calldata _strategies
    ) external view returns (uint256) {
        // This check is basically ensures that if there is a loss on the senior vault strategies
        // that are reported by "harvestAndReport" on the strategy level but not yet realized on the vault level.
        for (uint256 i = 0; i < _strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(_strategies[i]).current_debt;
            if (debt > 0) {
                if (
                    SENIOR_VAULT.assess_share_of_unrealised_losses(
                        _strategies[i],
                        debt
                    ) !=
                    0 ||
                    // but we also need to check if there are losses on the vaults strategies
                    // that are not reported by "harvestAndReport" on the strategy level.
                    IMorphoLossAwareCompounder(_strategies[i]).lossExists()
                ) return 0;
            }
        }

        // but we also need to check if there are losses on the vaults strategies
        // that are not reported by "harvestAndReport" on the strategy level.
    }

    function report(
        address /* _strategy */,
        uint256 _gain,
        uint256 _loss
    ) external returns (uint256 _fees, uint256 _refunds) {
        require(msg.sender == address(SENIOR_VAULT), "only senior vault");

        if (_gain > 0) {
            _fees = (_gain * seniorVaultPerformanceFee) / MAX_BPS;
            (uint16 protocolFee, ) = VAULT_FACTORY.protocol_fee_config(
                address(SENIOR_VAULT)
            );
            uint256 sharesToEarn = SENIOR_VAULT.convertToShares(_fees);
            uint256 protocolShares = (sharesToEarn * protocolFee) / MAX_BPS;
            _notifyRewardAmount(
                address(SENIOR_VAULT),
                sharesToEarn - protocolShares
            );
        } else {
            // Check if the auction was kicked and filled.
            if (auction != address(0)) {
                require(
                    Auction(auction).available(address(asset)) == 0,
                    "auction not filled"
                );
            }
            _refunds = Math.min(
                (_loss * refundRatio) / MAX_BPS,
                valueOfVault()
            );
            _freeFunds(_refunds);
            SENIOR_ASSET.forceApprove(address(SENIOR_VAULT), _refunds);
        }
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _claimAndSellRewards();
        _totalAssets = balanceOfAsset() + valueOfVault();
    }

    function _stake() internal virtual {}

    function _unStake(uint256 _amount) internal virtual {}

    function _claimAndSellRewards() internal virtual {}

    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfVault() public view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    function balanceOfStake() public view returns (uint256) {
        return 0;
    }

    function valueOfVault() public view returns (uint256) {
        return vault.convertToAssets(balanceOfVault() + balanceOfStake());
    }

    function vaultsMaxWithdraw() public view returns (uint256) {
        return vault.convertToAssets(vault.maxRedeem(address(this)));
    }

    function availableDepositLimit(
        address
    ) public view override returns (uint256) {
        return vault.maxDeposit(address(this));
    }

    /**
     * @dev Convert the amount of `asset` to `seniorAsset`.
     * @param _amount The amount of `asset` to convert.
     * @return The amount of `seniorAsset` that corresponds to the `_amount` of `asset`.
     */
    function _fromAssetToSeniorAsset(
        uint256 _amount
    ) internal view returns (uint256) {
        if (address(assetToSeniorAssetOracle) == address(0)) {
            // means that senior asset and asset are the same
            return _amount;
        }
        return (_amount * assetToSeniorAssetOracle.getRate()) / WAD;
    }

    /**
     * @dev Convert the amount of `seniorAsset` to `asset`.
     * @param _amount The amount of `seniorAsset` to convert.
     * @return The amount of `asset` that corresponds to the `_amount` of `seniorAsset`.
     */
    function _fromSeniorAssetToAsset(
        uint256 _amount
    ) internal view returns (uint256) {
        if (address(assetToSeniorAssetOracle) == address(0)) {
            // means that senior asset and asset are the same
            return _amount;
        }
        return (_amount * WAD) / assetToSeniorAssetOracle.getRate();
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
        address[] memory strategies = SENIOR_VAULT.get_default_queue();
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(strategies[i]).current_debt;
            if (debt > 0) {
                _loss += SENIOR_VAULT.assess_share_of_unrealised_losses(
                    strategies[i],
                    debt
                );
            }
        }

        if (_loss > 0) {
            if (auction != address(0)) {
                uint256 toAuction = Math.min(
                    _fromSeniorAssetToAsset((_loss * refundRatio) / MAX_BPS),
                    valueOfVault()
                );
                toAuction = Math.min(toAuction, vaultsMaxWithdraw());
                _freeFunds(toAuction);
                asset.safeTransfer(address(auction), toAuction);
                Auction(auction).kick(address(asset));
                // Eat the loss.
                IKeeper(TokenizedStrategy.keeper()).report(address(this));
            }
        }
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view override returns (bool) {
        address[] memory strategies = SENIOR_VAULT.get_default_queue();
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 debt = SENIOR_VAULT.strategies(strategies[i]).current_debt;
            if (debt > 0) {
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
        return false;
    }

    /**
     * @dev Set the auction address.
     * @param _auction The address of the auction.
     */
    function setAuction(address _auction) external onlyEmergencyAuthorized {
        if (_auction != address(0)) {
            require(
                Auction(_auction).want() == address(SENIOR_ASSET),
                "wrong want"
            );
            require(
                Auction(_auction).receiver() == address(this),
                "wrong receiver"
            );
        }
        auction = _auction;
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

    function enableAuction(
        address _from,
        address _auction
    ) external onlyEmergencyAuthorized {
        require(
            _auction == auction || _auction == rewardAuction,
            "wrong auction"
        );
        if (_auction == auction) {
            // asset to senior asset auction
            require(_from == address(asset), "wrong from");
        } else {
            // reward auction
            require(
                _from != address(asset) &&
                    _from != address(SENIOR_ASSET) &&
                    _from != address(SENIOR_VAULT),
                "wrong from"
            );
        }
        Auction(_auction).enable(_from);
    }

    /**
     * @dev Set the asset to senior oracle address.
     * @param _assetToSeniorAssetOracle The address of the asset to senior asset oracle.
     */
    function setAssetToSeniorAssetOracle(
        address _assetToSeniorAssetOracle
    ) external onlyEmergencyAuthorized {
        require(
            IOracle(_assetToSeniorAssetOracle).getRate() > 0,
            "invalid oracle"
        );
        assetToSeniorAssetOracle = IOracle(_assetToSeniorAssetOracle);
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

    // Tokenized staker override
    function _notifyRewardAmount(
        address _rewardToken,
        uint256 _rewardAmount
    ) internal override updateReward(address(0)) {
        Reward memory _rewardData = rewardData[_rewardToken];
        require(_rewardAmount > 0 && _rewardAmount < 1e30, "bad reward value");

        // If total supply is 0, send tokens to management instead of reverting.
        // Prevent footguns if _notifyRewardInstant() is part of predeposit hooks.
        uint256 totalSupply = _totalSupply();
        if (totalSupply == 0) {
            address management = TokenizedStrategy.management();

            ERC20(_rewardToken).safeTransfer(management, _rewardAmount);
            emit NotifiedWithZeroSupply(_rewardToken, _rewardAmount);
            return;
        }

        // this is the only part of the struct that will be the same for instant or normal
        _rewardData.lastUpdateTime = uint96(block.timestamp);

        /// @dev A rewardsDuration of 1 dictates instant release of rewards
        if (_rewardData.rewardsDuration == 1) {
            // Update lastNotifyTime and lastRewardRate if needed (would revert if in the same block otherwise)
            if (uint96(block.timestamp) != _rewardData.lastNotifyTime) {
                _rewardData.lastRewardRate = uint128(
                    _rewardAmount /
                        (block.timestamp - _rewardData.lastNotifyTime)
                );
                _rewardData.lastNotifyTime = uint96(block.timestamp);
            }

            // Update rewardRate, lastUpdateTime, periodFinish
            _rewardData.rewardRate = 0;
            _rewardData.periodFinish = uint96(block.timestamp);

            // Instantly release rewards by modifying rewardPerTokenStored
            _rewardData.rewardPerTokenStored = uint128(
                _rewardData.rewardPerTokenStored +
                    (_rewardAmount * PRECISION) /
                    totalSupply
            );
        } else {
            // store current rewardRate
            _rewardData.lastRewardRate = _rewardData.rewardRate;
            _rewardData.lastNotifyTime = uint96(block.timestamp);

            // update our rewardData with our new rewardRate
            if (block.timestamp >= _rewardData.periodFinish) {
                _rewardData.rewardRate = uint128(
                    _rewardAmount / _rewardData.rewardsDuration
                );
            } else {
                _rewardData.rewardRate = uint128(
                    (_rewardAmount +
                        (_rewardData.periodFinish - block.timestamp) *
                        _rewardData.rewardRate) / _rewardData.rewardsDuration
                );
            }

            // update time-based struct fields
            _rewardData.periodFinish = uint96(
                block.timestamp + _rewardData.rewardsDuration
            );
        }

        // make sure we have enough reward token for our new rewardRate
        // NOTE: This must need to be commented because report mints the shares after the report call.
        // require(
        //     _rewardData.rewardRate <=
        //         (ERC20(_rewardToken).balanceOf(address(this)) /
        //             _rewardData.rewardsDuration),
        //     "Not enough balance"
        // );

        // write to storage
        rewardData[_rewardToken] = _rewardData;
        emit RewardAdded(_rewardToken, _rewardAmount);
    }
}
