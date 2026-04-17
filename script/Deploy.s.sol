pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, VM} from "./ScriptBase.s.sol";
import {NoLossLottery} from "../src/NoLossLottery.sol";
import {SignatureRandomnessVerifier} from "../src/SignatureRandomnessVerifier.sol";

contract DeployNoLossLottery is Script {
    function run() external override {
        uint256 deployerKey = VM.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = VM.envAddress("OWNER");
        address operator = VM.envAddress("OPERATOR");
        address guardian = VM.envAddress("GUARDIAN");
        address treasury = VM.envAddress("TREASURY");
        address backendSigner = VM.envAddress("BACKEND_SIGNER");
        IERC20 asset = IERC20(VM.envAddress("ASSET"));
        IERC4626 vault = IERC4626(VM.envAddress("VAULT"));

        VM.startBroadcast(deployerKey);
        SignatureRandomnessVerifier verifier = new SignatureRandomnessVerifier(owner, backendSigner);
        NoLossLottery implementation = new NoLossLottery();
        bytes memory initData =
            abi.encodeCall(NoLossLottery.initialize, (owner, operator, guardian, treasury, asset, vault, verifier));
        new ERC1967Proxy(address(implementation), initData);
        VM.stopBroadcast();
    }
}
