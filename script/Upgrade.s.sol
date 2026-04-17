pragma solidity ^0.8.26;

import {Script, VM} from "./ScriptBase.s.sol";
import {NoLossLottery} from "../src/NoLossLottery.sol";
import {NoLossLotteryV2} from "../src/NoLossLotteryV2.sol";

contract UpgradeNoLossLottery is Script {
    function run() external override {
        uint256 deployerKey = VM.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = VM.envAddress("PROXY");

        VM.startBroadcast(deployerKey);
        NoLossLotteryV2 newImplementation = new NoLossLotteryV2();
        NoLossLottery(proxy).upgradeToAndCall(address(newImplementation), "");
        VM.stopBroadcast();
    }
}
