// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
import {Yumbrella} from "./Yumbrella.sol";
import {MorphoLossAwareCompounder} from "./MorphoLossAwareCompounder.sol";
import {IYumbrella} from "./interfaces/IYumbrella.sol";
import {IMorphoLossAwareCompounder} from "./interfaces/IMorphoLossAwareCompounder.sol";
import {IYumbrellaKeeper} from "./interfaces/IYumbrellaKeeper.sol";

/// @notice One-shot orchestrator to deploy and wire a Yumbrella trio.
/// @dev Mirrors setup flow used in tests: deploy strategy pair + vault and wire modules.
contract TrioFactory {
    /// @notice Emitted when a full trio is deployed and configured.
    event NewTrio(
        address indexed yumbrella,
        address indexed morphoLossAwareCompounder,
        address indexed seniorVault
    );

    /// @notice Management address for updating deployment dependencies.
    address public management;

    /// @notice Default performance fee recipient for deployed strategies.
    address public performanceFeeRecipient;

    /// @notice Default keeper for deployed strategies.
    address public keeper;

    /// @notice Default emergency admin for deployed strategies.
    address public emergencyAdmin;

    /// @notice Default Yumbrella loss limit ratio in bps.
    uint256 public yumbrellaLossLimitRatio = 9_999;

    /// @notice Keeper coordinator used by deployed strategies.
    IYumbrellaKeeper public yumbrellaKeeper;

    /// @notice Yearn V3 vault factory used to deploy senior vaults.
    IVaultFactory public vaultFactory;

    /// @notice Input params for full trio deployment.
    struct DeployParams {
        address asset;
        address yieldVault;
        address morphoVault;
        address assetToSeniorOracle;
        string yumbrellaName;
        string morphoName;
        string seniorVaultName;
        string seniorVaultSymbol;
        uint256 seniorVaultProfitMaxUnlockTime;
        address vaultManagement;
        address finalRoleManager;
        uint256 morphoLossLimitRatio;
    }

    modifier onlyManagement() {
        require(msg.sender == management, "!management");
        _;
    }

    /// @notice Initializes the trio factory.
    /// @param _management Management address.
    /// @param _performanceFeeRecipient Default performance fee recipient for deployed strategies.
    /// @param _keeper Default keeper for deployed strategies.
    /// @param _emergencyAdmin Default emergency admin for deployed strategies.
    /// @param _yumbrellaKeeper Keeper coordinator address.
    /// @param _vaultFactory Yearn vault factory address.
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin,
        address _yumbrellaKeeper,
        address _vaultFactory
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
        yumbrellaKeeper = IYumbrellaKeeper(_yumbrellaKeeper);
        vaultFactory = IVaultFactory(_vaultFactory);
    }

    /// @notice Deploys and wires a full trio (Morpho strategy + senior vault + Yumbrella).
    /// @dev This contract must have the required permissions in keeper/governance/factory/vault roles.
    /// @param p Deployment params.
    /// @return yumbrella Deployed Yumbrella strategy.
    /// @return morphoLossAwareCompounder Deployed Morpho loss-aware strategy.
    /// @return seniorVault Deployed senior vault.
    function deployTrio(
        DeployParams calldata p
    )
        external
        onlyManagement
        returns (
            address yumbrella,
            address morphoLossAwareCompounder,
            address seniorVault
        )
    {
        morphoLossAwareCompounder = _deployMorphoLossAwareCompounder(p);
        seniorVault = _deployAndConfigureSeniorVault(
            p,
            morphoLossAwareCompounder
        );
        yumbrella = _deployAndConfigureYumbrella(
            p,
            seniorVault,
            morphoLossAwareCompounder
        );

        yumbrellaKeeper.setTrio(
            yumbrella,
            morphoLossAwareCompounder,
            seniorVault
        );

        if (p.finalRoleManager != address(0)) {
            IVault(seniorVault).transfer_role_manager(p.finalRoleManager);
        }

        IMorphoLossAwareCompounder(morphoLossAwareCompounder)
            .setPendingManagement(management);
        IYumbrella(yumbrella).setPendingManagement(management);

        emit NewTrio(yumbrella, morphoLossAwareCompounder, seniorVault);
    }

    /// @notice Updates deployment dependencies used for new trios.
    /// @param _yumbrellaKeeper New keeper coordinator.
    /// @param _vaultFactory New vault factory.
    function setDependencies(
        address _yumbrellaKeeper,
        address _vaultFactory
    ) external onlyManagement {
        yumbrellaKeeper = IYumbrellaKeeper(_yumbrellaKeeper);
        vaultFactory = IVaultFactory(_vaultFactory);
    }

    /// @notice Updates default strategy role addresses for new deployments.
    /// @param _performanceFeeRecipient New default performance fee recipient.
    /// @param _keeper New default keeper.
    /// @param _emergencyAdmin New default emergency admin.
    function setStrategyAddresses(
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) external onlyManagement {
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    /// @notice Sets default Yumbrella loss limit ratio for new deployments.
    /// @param _newLossLimitRatio New loss limit ratio in bps.
    function setYumbrellaLossLimitRatio(
        uint256 _newLossLimitRatio
    ) external onlyManagement {
        require(_newLossLimitRatio <= 10_000, "!loss limit");
        yumbrellaLossLimitRatio = _newLossLimitRatio;
    }

    /// @notice Updates factory management.
    /// @param _management New management address.
    function setManagement(address _management) external onlyManagement {
        management = _management;
    }

    function _deployMorphoLossAwareCompounder(
        DeployParams calldata p
    ) internal returns (address morphoLossAwareCompounder) {
        morphoLossAwareCompounder = address(
            new MorphoLossAwareCompounder(p.asset, p.morphoName, p.morphoVault)
        );
        IMorphoLossAwareCompounder(morphoLossAwareCompounder)
            .setPerformanceFeeRecipient(performanceFeeRecipient);
        IMorphoLossAwareCompounder(morphoLossAwareCompounder).setKeeper(keeper);
        IMorphoLossAwareCompounder(morphoLossAwareCompounder).setEmergencyAdmin(
            emergencyAdmin
        );
        IBaseHealthCheck(morphoLossAwareCompounder).setLossLimitRatio(
            p.morphoLossLimitRatio
        );
    }

    function _deployAndConfigureSeniorVault(
        DeployParams calldata p,
        address morphoLossAwareCompounder
    ) internal returns (address seniorVault) {
        seniorVault = vaultFactory.deploy_new_vault(
            p.asset,
            p.seniorVaultName,
            p.seniorVaultSymbol,
            address(this),
            p.seniorVaultProfitMaxUnlockTime
        );

        IVault(seniorVault).set_role(address(this), Roles.ALL);
        IVault(seniorVault).set_role(p.vaultManagement, Roles.ALL);
        IVault(seniorVault).set_role(address(yumbrellaKeeper), Roles.ALL);
        IVault(seniorVault).set_deposit_limit(type(uint256).max);

        IMorphoLossAwareCompounder(morphoLossAwareCompounder).setAllowed(
            seniorVault,
            true
        );
    }

    function _deployAndConfigureYumbrella(
        DeployParams calldata p,
        address seniorVault,
        address morphoLossAwareCompounder
    ) internal returns (address yumbrella) {
        yumbrella = address(
            new Yumbrella(
                p.asset,
                p.yumbrellaName,
                seniorVault,
                p.assetToSeniorOracle,
                p.yieldVault
            )
        );
        IYumbrella(yumbrella).setPerformanceFeeRecipient(
            performanceFeeRecipient
        );
        IYumbrella(yumbrella).setKeeper(keeper);
        IYumbrella(yumbrella).setEmergencyAdmin(emergencyAdmin);
        IYumbrella(yumbrella).setLossLimitRatio(yumbrellaLossLimitRatio);
        IVault(seniorVault).set_deposit_limit_module(yumbrella);
        IVault(seniorVault).set_withdraw_limit_module(yumbrella);
        IVault(seniorVault).set_accountant(yumbrella);
        IVault(seniorVault).add_strategy(morphoLossAwareCompounder);
        IVault(seniorVault).update_max_debt_for_strategy(
            morphoLossAwareCompounder,
            type(uint256).max
        );
        IVault(seniorVault).set_use_default_queue(true);
        IVault(seniorVault).set_auto_allocate(true);
    }
}

