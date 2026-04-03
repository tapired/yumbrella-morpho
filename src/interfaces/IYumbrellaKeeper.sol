pragma solidity ^0.8.18;

interface IYumbrellaKeeper {
    function setKeeper(address _keeper, bool _status) external;
    function setTrio(
        address _yumbrella,
        address _morphoLossAwareCompounder,
        address _seniorVault
    ) external;
    function report(
        address _morphoLossAwareCompounder
    ) external returns (uint256 profit, uint256 loss);
    function reportYumbrellaAndMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    )
        external
        returns (
            uint256 yumbrellaProfit,
            uint256 yumbrellaLoss,
            uint256 morphoProfit,
            uint256 morphoLoss
        );
    function reportYumbrella(
        address _morphoLossAwareCompounder
    ) external returns (uint256 profit, uint256 loss);
    function reportMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external returns (uint256 profit, uint256 loss);
    function reportSeniorVault(
        address _morphoLossAwareCompounder
    ) external returns (uint256 profit, uint256 loss);
    function tendYumbrellaAndMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external;
    function tendYumbrella(address _morphoLossAwareCompounder) external;
    function tendMorphoLossAwareCompounder(
        address _morphoLossAwareCompounder
    ) external;
}
