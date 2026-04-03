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

    /// @notice Initializes factory role addresses.
    /// @param _management Management address for factory updates.
    /// @param _performanceFeeRecipient Default performance fee recipient for new strategies.
    /// @param _keeper Default keeper for new strategies.
    /// @param _emergencyAdmin Default emergency admin for new strategies.
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

    /// @notice Deploys a new Morpho loss-aware compounder.
    /// @param _asset Underlying asset.
    /// @param _name Strategy name.
    /// @param _vault Target MetaMorpho vault.
    /// @return Address of the deployed strategy.
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

    /// @notice Updates default role addresses used for future deployments.
    /// @param _management New management address.
    /// @param _performanceFeeRecipient New performance fee recipient.
    /// @param _keeper New keeper address.
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

    /// @notice Checks if a strategy is the tracked deployment for an asset/vault pair.
    /// @param _asset Underlying asset.
    /// @param _vault Target MetaMorpho vault.
    /// @param _strategy Strategy address to validate.
    /// @return True if it matches the recorded deployment, false otherwise.
    function isDeployedStrategy(
        address _asset,
        address _vault,
        address _strategy
    ) external view returns (bool) {
        return deployments[_asset][_vault] == _strategy;
    }
}
