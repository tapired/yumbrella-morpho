// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoCompounder} from "./MorphoCompounder.sol";
import {MinimalMorphoExpectedSupplyLib, IMorphoLike, MarketParams} from "./lib/MinimalMorphoExpectedSupplyLib.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

interface IMetaMorpho {
    function lostAssets() external view returns (uint256);
    function MORPHO() external view returns (IMorphoLike);
    function withdrawQueueLength() external view returns (uint256);
    function withdrawQueue(uint256 i) external view returns (bytes32);
    function lastTotalAssets() external view returns (uint256);
}

contract MorphoLossAwareCompounder is MorphoCompounder {
    using SafeERC20 for ERC20;
    using MinimalMorphoExpectedSupplyLib for IMorphoLike;

    uint256 public lastLostAssetsOnMorpho;
    uint256 public lastMorphoLosses;

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _vault
    ) MorphoCompounder(_asset, _name, _vault) {
        // initiate it.
        lastLostAssetsOnMorpho = IMetaMorpho(_vault).lostAssets();
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // override the _freeFunds function to calculate the losses on morpho since last report.
    // dont update the storage of lastLostAssetsOnMorpho.
    // function _freeFunds(uint256 _amount) internal override {
    //     // // calculate the losses on morpho since last report.
    //     // (uint256 totalLoss, ) = _calculateLoss();
    //     // uint256 actualTotalAssets;
    //     // if (totalLoss > TokenizedStrategy.totalAssets()) {
    //     //     actualTotalAssets = 0;
    //     // }
    //     // else {
    //     //     actualTotalAssets = TokenizedStrategy.totalAssets() - totalLoss;
    //     //     _amount = _amount * actualTotalAssets / TokenizedStrategy.totalAssets();
    //     // }

    //     // super._freeFunds(_amount);
    // }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        vault.deposit(0, address(this));

        // calculate the losses on morpho since last report.
        (uint256 newLosses, uint256 lostAssetsOnMorpho) = _calculateLoss();
        lastLostAssetsOnMorpho = lostAssetsOnMorpho;
        lastMorphoLosses += newLosses;

        uint256 fullBalance = super._harvestAndReport();

        if (fullBalance > lastMorphoLosses) {
            return fullBalance - lastMorphoLosses;
        } else {
            return 0;
        }
    }

    function lossExists() external view returns (bool) {
        uint256 lostAssetsOnMorpho = IMetaMorpho(address(vault)).lostAssets();
        if (lostAssetsOnMorpho > lastLostAssetsOnMorpho) return true; // already accrued, early exit
        return viewPendingLostAssets() > lostAssetsOnMorpho;
    }

    function viewPendingLostAssets() public view returns (uint256) {
        IMetaMorpho morphoVault = IMetaMorpho(address(vault));
        IMorphoLike morpho = morphoVault.MORPHO();

        uint256 realTotalAssets;
        uint256 length = morphoVault.withdrawQueueLength();

        for (uint256 i; i < length; ++i) {
            bytes32 id = morphoVault.withdrawQueue(i);
            MarketParams memory marketParams = morpho.idToMarketParams(id);

            realTotalAssets += MinimalMorphoExpectedSupplyLib
                .expectedSupplyAssets(
                    morpho,
                    marketParams,
                    address(morphoVault)
                );
        }

        uint256 last = morphoVault.lastTotalAssets();
        uint256 lost = morphoVault.lostAssets();

        uint256 accountedRealAssets = last - lost;

        if (realTotalAssets < accountedRealAssets) {
            return last - realTotalAssets;
        } else {
            return lost;
        }
    }

    function _calculateLoss()
        internal
        view
        returns (uint256 newLosses, uint256 lostAssetsOnMorpho)
    {
        lostAssetsOnMorpho = IMetaMorpho(address(vault)).lostAssets();
        uint256 lostAssetsSinceLastReport = lostAssetsOnMorpho -
            lastLostAssetsOnMorpho;
        newLosses =
            (vault.balanceOf(address(this)) * lostAssetsSinceLastReport) /
            vault.totalSupply();
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (allowed[_owner]) return super.availableDepositLimit(_owner);
        return 0;
    }

    function setAllowed(address _owner, bool _allowed) public onlyManagement {
        allowed[_owner] = _allowed;
    }
}
