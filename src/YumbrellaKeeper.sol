// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Governance} from "@periphery/utils/Governance.sol";
import {IYumbrella} from "./interfaces/IYumbrella.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

contract YumbrellaKeeper is Governance {
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

    function setKeeper(address _keeper, bool _status) external onlyGovernance {
        keepers[_keeper] = _status;
    }

    function setTrio(
        address _yumbrella,
        address _morphoLossAwareCompounder,
        address _seniorVault
    ) external onlyGovernance {
        trios[_morphoLossAwareCompounder] = Trio(_yumbrella, _seniorVault);
    }

    // called when there are losses on morpho loss aware compounder, full flow
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

    // handy function
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

    // Only reports for profits
    function reportYumbrella(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IYumbrella(trios[_morphoLossAwareCompounder].yumbrella)
            .report();
    }

    function reportMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IMorphoLossAwareCompounder(_morphoLossAwareCompounder)
            .report();
    }

    function reportSeniorVault(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) returns (uint256 profit, uint256 loss) {
        (profit, loss) = IVault(trios[_morphoLossAwareCompounder].seniorVault)
            .process_report(_morphoLossAwareCompounder);
    }

    // tends
    function tendYumbrellaAndMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IYumbrella(trios[_morphoLossAwareCompounder].yumbrella).tend();
        IMorphoLossAwareCompounder(_morphoLossAwareCompounder).tend();
    }

    function tendYumbrella(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IYumbrella(trios[_morphoLossAwareCompounder].yumbrella).tend();
    }

    function tendMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external onlyKeeper(msg.sender) {
        IMorphoLossAwareCompounder(_morphoLossAwareCompounder).tend();
    }
}
