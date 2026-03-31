// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IMorphoLossAwareCompounder is IStrategy {
    function lossExists() external view returns (bool);
}
