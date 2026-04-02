// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Yumbrella, ERC20} from "./Yumbrella.sol";
import {IYumbrella} from "./interfaces/IYumbrella.sol";

contract YumbrellaFactory {
    event NewYumbrella(address indexed yumbrella, address indexed asset);

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;
    uint256 public yumbrellaLossLimitRatio = 9_999;

    /// @notice Track the deployments. asset => pool => yumbrella
    mapping(address => address) public deployments;

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

    /**
     * @notice Deploy a new Yumbrella.
     * @param _asset The underlying asset for the strategy to use.
     * @return . The address of the new yumbrella.
     */
    function newYumbrella(
        address _asset,
        string calldata _name,
        address _seniorVault,
        address _assetToSeniorOracle,
        address _yieldVault
    ) external virtual returns (address) {
        // tokenized strategies available setters.
        IYumbrella _newYumbrella = IYumbrella(
            address(
                new Yumbrella(
                    _asset,
                    _name,
                    _seniorVault,
                    _assetToSeniorOracle,
                    _yieldVault
                )
            )
        );

        _newYumbrella.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newYumbrella.setKeeper(keeper);

        _newYumbrella.setPendingManagement(management);

        _newYumbrella.setEmergencyAdmin(emergencyAdmin);

        _newYumbrella.setLossLimitRatio(yumbrellaLossLimitRatio);

        emit NewYumbrella(address(_newYumbrella), _asset);

        deployments[_asset] = address(_newYumbrella);
        return address(_newYumbrella);
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

    function setYumbrellaLossLimitRatio(uint256 _newLossLimitRatio) external {
        require(msg.sender == management, "!management");
        require(_newLossLimitRatio < 10_000, "!loss limit");
        yumbrellaLossLimitRatio = _newLossLimitRatio;
    }

    function isDeployedStrategy(
        address _yumbrella
    ) external view returns (bool) {
        address _asset = IYumbrella(_yumbrella).asset();
        return deployments[_asset] == _yumbrella;
    }
}
