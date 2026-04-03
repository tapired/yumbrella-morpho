// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IBase4626Compounder} from "@periphery/Bases/4626Compounder/IBase4626Compounder.sol";

interface IMorphoLossAwareCompounder is IStrategy, IBase4626Compounder {
    function lossExists() external view returns (bool);

    function setAllowed(address _allowed, bool _status) external;

    function kickAuction(address _token) external returns (uint256);
}
