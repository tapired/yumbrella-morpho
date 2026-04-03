// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Governance} from "@periphery/utils/Governance.sol";
import {IYumbrella} from "./interfaces/IYumbrella.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

contract YumbrellaKeeper is Governance {
    /// @notice Initializes keeper governance.
    /// @param _governance Address allowed to configure keepers and trios.
    constructor(address _governance) Governance(_governance) {}

    struct Trio {
        address yumbrella;
        address seniorVault;
    }

    mapping(address => Trio) public trios;
    mapping(address => bool) public keepers;

    modifier onlyKeeper(address _keeper) {
        require(keepers[_keeper], "!keeper");
        _;
    }

    /// @notice Sets or unsets an address as an authorized keeper.
    /// @param _keeper Keeper address.
    /// @param _status True to allow, false to revoke.
    function setKeeper(address _keeper, bool _status) external onlyGovernance {
        keepers[_keeper] = _status;
    }

    /// @notice Registers the yumbrella and senior vault for a Morpho strategy.
    /// @param _yumbrella Yumbrella strategy address.
    /// @param _morphoLossAwareCompounder Morpho loss-aware compounder address.
    /// @param _seniorVault Senior vault address.
    function setTrio(
        address _yumbrella,
        address _morphoLossAwareCompounder,
        address _seniorVault
    ) external onlyGovernance {
        trios[_morphoLossAwareCompounder] = Trio(_yumbrella, _seniorVault);
    }

    /// @notice Full loss-sync flow called by the Morpho strategy itself.
    /// @param _morphoLossAwareCompounder Morpho strategy address.
    /// @return profit Profit reported by Morpho strategy.
    /// @return loss Loss reported by Morpho strategy.
    function report(
        address _morphoLossAwareCompounder
    ) external returns (uint256 profit, uint256 loss) {
        require(msg.sender == _morphoLossAwareCompounder, "!womp womp");

        (profit, loss) = IMorphoLossAwareCompounder(_morphoLossAwareCompounder)
            .report();
        IVault(trios[_morphoLossAwareCompounder].seniorVault).process_report(
            _morphoLossAwareCompounder
        );
        IYumbrella(trios[_morphoLossAwareCompounder].yumbrella).report();
    }

    /// @notice Keeper helper to report Morpho then Yumbrella.
    /// @param _morphoLossAwareCompounder Morpho strategy address.
    /// @return yumbrellaProfit Profit reported by Yumbrella.
    /// @return yumbrellaLoss Loss reported by Yumbrella.
    /// @return morphoProfit Profit reported by Morpho strategy.
    /// @return morphoLoss Loss reported by Morpho strategy.
    function reportYumbrellaAndMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    )
        external
        onlyKeeper(msg.sender)
        returns (
            uint256 yumbrellaProfit,
            uint256 yumbrellaLoss,
            uint256 morphoProfit,
            uint256 morphoLoss
        )
    {
        (morphoProfit, morphoLoss) = IMorphoLossAwareCompounder(
            _morphoLossAwareCompounder
        ).report();
        (yumbrellaProfit, yumbrellaLoss) = IYumbrella(
            trios[_morphoLossAwareCompounder].yumbrella
        ).report();
    }

    /// @notice Reports Yumbrella only.
    /// @param _morphoLossAwareCompounder Morpho strategy address used to resolve trio.
    /// @return profit Profit reported by Yumbrella.
    /// @return loss Loss reported by Yumbrella.
    function reportYumbrella(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IYumbrella(trios[_morphoLossAwareCompounder].yumbrella)
            .report();
    }

    /// @notice Reports Morpho strategy only.
    /// @param _morphoLossAwareCompounder Morpho strategy address.
    /// @return profit Profit reported by Morpho strategy.
    /// @return loss Loss reported by Morpho strategy.
    function reportMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IMorphoLossAwareCompounder(_morphoLossAwareCompounder)
            .report();
    }

    /// @notice Processes senior vault report for the Morpho strategy.
    /// @param _morphoLossAwareCompounder Morpho strategy address.
    /// @return profit Profit accounted by senior vault.
    /// @return loss Loss accounted by senior vault.
    function reportSeniorVault(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IVault(trios[_morphoLossAwareCompounder].seniorVault)
            .process_report(_morphoLossAwareCompounder);
    }

    /// @notice Tends both Yumbrella and Morpho strategies.
    /// @param _morphoLossAwareCompounder Morpho strategy address used to resolve trio.
    function tendYumbrellaAndMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IYumbrella(trios[_morphoLossAwareCompounder].yumbrella).tend();
        IMorphoLossAwareCompounder(_morphoLossAwareCompounder).tend();
    }

    /// @notice Tends Yumbrella only.
    /// @param _morphoLossAwareCompounder Morpho strategy address used to resolve trio.
    function tendYumbrella(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IYumbrella(trios[_morphoLossAwareCompounder].yumbrella).tend();
    }

    /// @notice Tends Morpho strategy only.
    /// @param _morphoLossAwareCompounder Morpho strategy address.
    function tendMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IMorphoLossAwareCompounder(_morphoLossAwareCompounder).tend();
    }
}
