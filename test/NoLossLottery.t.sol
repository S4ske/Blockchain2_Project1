pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NoLossLottery} from "../src/NoLossLottery.sol";
import {NoLossLotteryV2} from "../src/NoLossLotteryV2.sol";
import {SignatureRandomnessVerifier} from "../src/SignatureRandomnessVerifier.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockERC4626Vault} from "../src/mocks/MockERC4626Vault.sol";
import {TestBase, VM} from "./TestBase.sol";

contract NoLossLotteryTest is TestBase {
    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;
    uint256 internal constant BACKEND_PK = 0xBEEF;

    MockERC20 internal asset;
    MockERC4626Vault internal vault;
    SignatureRandomnessVerifier internal verifier;
    NoLossLottery internal lottery;

    address internal owner = address(0x1001);
    address internal operator = address(0x1002);
    address internal guardian = address(0x1003);
    address internal treasury = address(0x1004);
    address internal sponsor = address(0x1005);
    address internal alice;
    address internal bob;
    address internal backendSigner;

    function setUp() public {
        alice = VM.addr(ALICE_PK);
        bob = VM.addr(BOB_PK);
        backendSigner = VM.addr(BACKEND_PK);

        asset = new MockERC20("Mock USDC", "mUSDC", 18);
        vault = new MockERC4626Vault(asset, "Vault Share", "vSHARE");
        verifier = new SignatureRandomnessVerifier(owner, backendSigner);

        NoLossLottery implementation = new NoLossLottery();
        bytes memory initData =
            abi.encodeCall(NoLossLottery.initialize, (owner, operator, guardian, treasury, asset, vault, verifier));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        lottery = NoLossLottery(address(proxy));

        asset.mint(alice, 1_000 ether);
        asset.mint(bob, 1_000 ether);
        asset.mint(sponsor, 1_000 ether);

        VM.startPrank(alice);
        asset.approve(address(lottery), type(uint256).max);
        VM.stopPrank();

        VM.startPrank(bob);
        asset.approve(address(lottery), type(uint256).max);
        VM.stopPrank();

        VM.startPrank(sponsor);
        asset.approve(address(vault), type(uint256).max);
        VM.stopPrank();
    }

    function testFullEpochFlowWeightedWinnerAndPrize() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.prank(bob);
        lottery.deposit(300 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 400 ether);

        VM.prank(sponsor);
        vault.donateYield(40 ether);

        VM.warp(block.timestamp + 7 days);

        bytes32 randomWord = bytes32(uint256(150 ether));
        bytes memory proof = _signRandomness(1, randomWord, block.timestamp + 1 days);

        VM.prank(operator);
        lottery.finalizeEpoch(1, randomWord, block.timestamp + 1 days, proof, 440 ether);

        NoLossLottery.Epoch memory finishedEpoch = lottery.epoch(1);
        assertEq(uint256(finishedEpoch.status), uint256(NoLossLottery.EpochStatus.Finalized));
        assertEq(finishedEpoch.winner, bob);
        assertEq(finishedEpoch.yieldAward, 40 ether);
        assertEq(asset.balanceOf(address(lottery)), 440 ether);

        VM.prank(alice);
        lottery.claim(1);

        VM.prank(bob);
        lottery.claim(1);

        assertEq(asset.balanceOf(alice), 1_000 ether);
        assertEq(asset.balanceOf(bob), 1_040 ether);
        assertEq(asset.balanceOf(address(lottery)), 0);
    }

    function testRandomnessVerificationRejectsInvalidSigner() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 100 ether);

        VM.prank(sponsor);
        vault.donateYield(10 ether);

        VM.warp(block.timestamp + 7 days);

        uint256 wrongKey = 0xDEAD;
        bytes32 randomWord = bytes32(uint256(1));
        bytes memory proof = _signRandomnessWithKey(1, randomWord, block.timestamp + 1 days, wrongKey);

        VM.prank(operator);
        VM.expectRevert(abi.encodeWithSelector(SignatureRandomnessVerifier.InvalidSigner.selector, VM.addr(wrongKey)));
        lottery.finalizeEpoch(1, randomWord, block.timestamp + 1 days, proof, 110 ether);
    }

    function testRandomnessVerificationRejectsExpiredPayload() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 100 ether);

        VM.prank(sponsor);
        vault.donateYield(10 ether);

        VM.warp(block.timestamp + 7 days);

        bytes32 randomWord = bytes32(uint256(1));
        uint256 expiredAt = block.timestamp - 1;
        bytes memory proof = _signRandomness(1, randomWord, expiredAt);

        VM.prank(operator);
        VM.expectRevert(
            abi.encodeWithSelector(SignatureRandomnessVerifier.RandomnessExpired.selector, expiredAt, block.timestamp)
        );
        lottery.finalizeEpoch(1, randomWord, expiredAt, proof, 110 ether);
    }

    function testGuardianPauseBlocksDeposits() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(guardian);
        lottery.pause();

        VM.prank(alice);
        VM.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));
        lottery.deposit(1 ether);
    }

    function testEmergencyCancelLockedEpochRefundsPrincipalAndSweepsYield() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(200 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 200 ether);

        VM.prank(sponsor);
        vault.donateYield(20 ether);

        VM.prank(guardian);
        lottery.pause();

        VM.prank(owner);
        lottery.cancelLockedEpoch(1, 220 ether);

        NoLossLottery.Epoch memory cancelledEpoch = lottery.epoch(1);
        assertEq(uint256(cancelledEpoch.status), uint256(NoLossLottery.EpochStatus.Cancelled));
        assertEq(asset.balanceOf(treasury), 20 ether);

        VM.prank(alice);
        lottery.claim(1);

        assertEq(asset.balanceOf(alice), 1_000 ether);
        assertEq(asset.balanceOf(address(lottery)), 0);
    }

    function testEmergencyCancelOpenEpochRefundsDepositors() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(80 ether);

        VM.prank(bob);
        lottery.deposit(20 ether);

        VM.prank(guardian);
        lottery.pause();

        VM.prank(owner);
        lottery.cancelOpenEpoch(1);

        NoLossLottery.Epoch memory cancelledEpoch = lottery.epoch(1);
        assertEq(uint256(cancelledEpoch.status), uint256(NoLossLottery.EpochStatus.Cancelled));

        VM.prank(alice);
        lottery.claim(1);

        VM.prank(bob);
        lottery.claim(1);

        assertEq(asset.balanceOf(alice), 1_000 ether);
        assertEq(asset.balanceOf(bob), 1_000 ether);
        assertEq(asset.balanceOf(address(lottery)), 0);
    }

    function testCanOpenNextEpochBeforePreviousClaimsAreComplete() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 100 ether);

        VM.prank(sponsor);
        vault.donateYield(10 ether);

        VM.warp(block.timestamp + 7 days);

        bytes32 randomWord = bytes32(uint256(1));
        bytes memory proof = _signRandomness(1, randomWord, block.timestamp + 1 days);

        VM.prank(operator);
        lottery.finalizeEpoch(1, randomWord, block.timestamp + 1 days, proof, 110 ether);

        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        assertEq(lottery.currentEpochId(), 2);

        VM.prank(alice);
        lottery.claim(1);

        assertEq(asset.balanceOf(alice), 1_010 ether);
    }

    function testDepositAtEpochEndReverts() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.warp(block.timestamp + 1 days);

        VM.prank(alice);
        VM.expectRevert(
            abi.encodeWithSelector(NoLossLottery.DepositWindowClosed.selector, 1, block.timestamp, block.timestamp)
        );
        lottery.deposit(1 ether);
    }

    function testMultipleDepositsPreserveWeightedSelection() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.prank(bob);
        lottery.deposit(50 ether);

        VM.prank(bob);
        lottery.deposit(50 ether);

        assertEq(lottery.previewWinner(1, bytes32(uint256(150 ether))), bob);
        assertEq(lottery.previewWinner(1, bytes32(uint256(99 ether))), alice);
    }

    function testCannotRescueVaultShares() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(100 ether);

        VM.warp(block.timestamp + 1 days + 1);

        VM.prank(operator);
        lottery.closeEpoch(1, 100 ether);

        VM.prank(guardian);
        lottery.pause();

        VM.prank(owner);
        VM.expectRevert(abi.encodeWithSelector(NoLossLottery.UnsupportedRescueToken.selector, address(vault)));
        lottery.rescueUnsupportedToken(IERC20(address(vault)), owner, 1);
    }

    function testUpgradePreservesState() public {
        VM.prank(owner);
        lottery.openEpoch(uint64(block.timestamp + 1 days), uint64(block.timestamp + 8 days));

        VM.prank(alice);
        lottery.deposit(25 ether);

        NoLossLotteryV2 newImplementation = new NoLossLotteryV2();

        VM.prank(owner);
        lottery.upgradeToAndCall(address(newImplementation), "");

        assertEq(NoLossLotteryV2(address(lottery)).version(), 2);
        assertEq(lottery.userDeposit(1, alice), 25 ether);
        assertEq(lottery.owner(), owner);
    }

    function _signRandomness(uint256 epochId, bytes32 randomWord, uint256 validUntil) internal returns (bytes memory) {
        return _signRandomnessWithKey(epochId, randomWord, validUntil, BACKEND_PK);
    }

    function _signRandomnessWithKey(uint256 epochId, bytes32 randomWord, uint256 validUntil, uint256 privateKey)
        internal
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(verifier.TYPEHASH(), address(lottery), block.chainid, epochId, randomWord, validUntil)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
