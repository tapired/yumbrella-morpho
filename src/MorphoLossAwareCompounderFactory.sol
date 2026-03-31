// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {MorphoLossAwareCompounder} from "./MorphoLossAwareCompounder.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";

contract MorphoLossAwareCompounderFactory {
    event NewMorphoLossAwareCompounder(
        address indexed strategy,
        address indexed asset,
        address indexed vault
    );

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    // Track deployments by asset and target vault.
    mapping(address => mapping(address => address)) public deployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    function newMorphoLossAwareCompounder(
        address _asset,
        string calldata _name,
        address _vault
    ) external virtual returns (address) {
        IMorphoLossAwareCompounder _strategy = IMorphoLossAwareCompounder(
            address(new MorphoLossAwareCompounder(_asset, _name, _vault))
        );

        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setKeeper(keeper);
        _strategy.setPendingManagement(management);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        deployments[_asset][_vault] = address(_strategy);
        emit NewMorphoLossAwareCompounder(address(_strategy), _asset, _vault);

        return address(_strategy);
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _asset,
        address _vault,
        address _strategy
    ) external view returns (bool) {
        return deployments[_asset][_vault] == _strategy;
    }
}
