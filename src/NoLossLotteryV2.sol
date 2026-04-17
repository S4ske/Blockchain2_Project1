pragma solidity ^0.8.26;

import {NoLossLottery} from "./NoLossLottery.sol";

contract NoLossLotteryV2 is NoLossLottery {
    function version() external pure returns (uint256) {
        return 2;
    }
}
