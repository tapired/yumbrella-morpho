// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {VyperDeployer} from "./VyperDeployer.sol";

import {Yumbrella, ERC20, IOracle, IVault} from "../../Yumbrella.sol";
import {MorphoLossAwareCompounder} from "../../MorphoLossAwareCompounder.sol";
import {IMorphoLossAwareCompounder} from "../../interfaces/IMorphoLossAwareCompounder.sol";
import {MorphoLossAwareCompounderFactory} from "../../MorphoLossAwareCompounderFactory.sol";
import {YumbrellaFactory} from "../../YumbrellaFactory.sol";
import {IYumbrella} from "../../interfaces/IYumbrella.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {YumbrellaKeeper} from "../../YumbrellaKeeper.sol";
import {IYumbrellaKeeper} from "../../interfaces/IYumbrellaKeeper.sol";
import {MockOracle} from "../Mocks/MockOracle.sol";
import {Clonable} from "@periphery/utils/Clonable.sol";

import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents, Clonable {
    // Contract instances that we will use repeatedly.
    ERC20 public asset; // yumbrella asset
    IYumbrella public yumbrella;
    YumbrellaFactory public yumbrellaFactory;
    MorphoLossAwareCompounderFactory public morphoLossAwareCompounderFactory;
    IMorphoLossAwareCompounder public morphoLossAwareCompounder;
    IVaultFactory public vaultFactory =
        IVaultFactory(0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F);

    IVault public seniorVault;
    ERC20 public seniorVaultAsset;
    IOracle public assetToSeniorOracle;
    IYumbrellaKeeper public yumbrellaKeeper;

    VyperDeployer public vyperDeployer = new VyperDeployer();

    mapping(string => address) public tokenAddrs;
    mapping(string => address) public yieldVaultAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public vaultManagement = address(2);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;
    address public yieldVault;
    address public morphoVault;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e6 * 1e6; // 1M USDC
    uint256 public minFuzzAmount = 1e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();
        _setYieldVaultAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);
        yieldVault = yieldVaultAddrs["USDC"];
        seniorVaultAsset = ERC20(tokenAddrs["USDC"]);
        morphoVault = 0xF9bdDd4A9b3A45f980e11fDDE96e16364dDBEc49; // yearn og usdc

        // Set decimals
        decimals = asset.decimals();

        yumbrellaKeeper = IYumbrellaKeeper(
            address(new YumbrellaKeeper(management))
        );
        vm.prank(management);
        yumbrellaKeeper.setKeeper(keeper, true);

        yumbrellaFactory = new YumbrellaFactory(
            management,
            performanceFeeRecipient,
            address(yumbrellaKeeper),
            emergencyAdmin
        );

        morphoLossAwareCompounderFactory = new MorphoLossAwareCompounderFactory(
            management,
            performanceFeeRecipient,
            address(yumbrellaKeeper),
            emergencyAdmin
        );

        morphoLossAwareCompounder = setUpMorphoLossAwareCompounder();
        seniorVault = setUpVault();

        assetToSeniorOracle = new MockOracle();

        // Deploy strategy and set variables
        yumbrella = IYumbrella(
            setUpYumbrella(address(seniorVault), address(assetToSeniorOracle))
        );

        vm.prank(management);
        yumbrellaKeeper.setTrio(
            address(yumbrella),
            address(morphoLossAwareCompounder),
            address(seniorVault)
        );

        factory = yumbrella.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(yumbrella), "yumbrella");
        vm.label(vaultManagement, "vaultManagement");
        vm.label(address(seniorVault), "seniorVault");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpMorphoLossAwareCompounder()
        public
        returns (IMorphoLossAwareCompounder)
    {
        IMorphoLossAwareCompounder _compounder = IMorphoLossAwareCompounder(
            morphoLossAwareCompounderFactory.newMorphoLossAwareCompounder(
                address(seniorVaultAsset),
                "Morpho Loss Aware Compounder",
                morphoVault
            )
        );

        vm.prank(management);
        _compounder.acceptManagement();

        vm.prank(management);
        IBaseHealthCheck(address(_compounder)).setLossLimitRatio(5_000); // 50%

        return _compounder;
    }

    function setUpVault() public returns (IVault) {
        address _vault = vaultFactory.deploy_new_vault(
            address(seniorVaultAsset),
            "Test vault",
            "tsVault",
            management,
            10 days
        );

        vm.prank(management);
        // Give the vault manager all the roles
        IVault(_vault).set_role(vaultManagement, Roles.ALL);

        vm.prank(management);
        // YumbrellaKeeper executes process_report via helper methods.
        IVault(_vault).set_role(address(yumbrellaKeeper), Roles.ALL);

        vm.prank(vaultManagement);
        IVault(_vault).set_deposit_limit(type(uint256).max);

        vm.prank(management);
        morphoLossAwareCompounder.setAllowed(_vault, true);

        return IVault(_vault);
    }

    function setUpYumbrella(
        address _seniorVault,
        address _assetToSeniorOracle
    ) public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IYumbrella _yumbrella = IYumbrella(
            address(
                yumbrellaFactory.newYumbrella(
                    address(asset),
                    "Tokenized Strategy",
                    address(seniorVault),
                    address(assetToSeniorOracle),
                    yieldVault
                )
            )
        );

        vm.prank(management);
        _yumbrella.acceptManagement();

        vm.prank(vaultManagement);
        seniorVault.set_deposit_limit_module(address(_yumbrella));

        vm.prank(vaultManagement);
        seniorVault.set_withdraw_limit_module(address(_yumbrella));

        vm.prank(vaultManagement);
        seniorVault.set_accountant(address(_yumbrella));

        vm.prank(vaultManagement);
        seniorVault.add_strategy(address(morphoLossAwareCompounder));

        vm.prank(vaultManagement);
        seniorVault.update_max_debt_for_strategy(
            address(morphoLossAwareCompounder),
            type(uint256).max
        );

        vm.prank(vaultManagement);
        seniorVault.set_use_default_queue(true);

        vm.prank(vaultManagement);
        seniorVault.set_auto_allocate(true);

        return address(_yumbrella);
    }

    function depositIntoYumbrella(
        IYumbrella _yumbrella,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_yumbrella), _amount);

        vm.prank(_user);
        _yumbrella.deposit(_amount, _user);
    }

    function depositIntoSeniorVault(
        IVault _seniorVault,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        seniorVaultAsset.approve(address(_seniorVault), _amount);

        vm.prank(_user);
        _seniorVault.deposit(_amount, _user);
    }

    function mintAndDepositIntoYumbrella(
        IYumbrella _yumbrella,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoYumbrella(_yumbrella, _user, _amount);
    }

    function mintAndDepositIntoSeniorVault(
        IVault _seniorVault,
        address _user,
        uint256 _amount
    ) public {
        airdrop(seniorVaultAsset, _user, _amount);
        depositIntoSeniorVault(_seniorVault, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkYumbrellaTotals(
        IYumbrella _yumbrella,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _yumbrella.totalAssets();
        uint256 _balance = ERC20(_yumbrella.asset()).balanceOf(
            address(_yumbrella)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        yumbrella.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function _setYieldVaultAddrs() internal {
        yieldVaultAddrs["USDC"] = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204; // yvUSDC-1
    }
}
