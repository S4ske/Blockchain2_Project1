pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IRandomnessVerifier} from "./interfaces/IRandomnessVerifier.sol";

contract NoLossLottery is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidEpochWindow();
    error PreviousEpochNotSettled(uint256 epochId);
    error UnauthorizedOperator(address account);
    error UnauthorizedGuardian(address account);
    error InvalidEpochState(uint256 epochId, EpochStatus status);
    error DepositWindowClosed(uint256 epochId, uint256 timestamp, uint256 depositEnd);
    error DepositAmountZero();
    error NoParticipants(uint256 epochId);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error PrincipalImpaired(uint256 principal, uint256 recovered);
    error InvalidVaultAsset(address expected, address actual);
    error NothingToClaim(uint256 epochId, address account);
    error AlreadyClaimed(uint256 epochId, address account);
    error UnsupportedRescueToken(address token);
    error InvalidWinnerSelection(uint256 epochId, uint256 target);

    enum EpochStatus {
        None,
        Open,
        Locked,
        Finalized,
        Cancelled
    }

    struct Epoch {
        uint64 depositStart;
        uint64 depositEnd;
        uint64 drawTime;
        EpochStatus status;
        uint256 totalPrincipal;
        uint256 vaultShares;
        uint256 yieldAward;
        uint256 remainingClaimable;
        address winner;
        bytes32 randomWord;
    }

    IERC20 public asset;
    IERC4626 public vault;
    IRandomnessVerifier public randomnessVerifier;
    address public operator;
    address public guardian;
    address public treasury;
    uint256 public currentEpochId;

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => mapping(address => uint256)) internal _userDeposits;
    mapping(uint256 => mapping(address => bool)) internal _claimed;
    mapping(uint256 => address[]) internal _participants;

    event OperatorUpdated(address indexed operator);
    event GuardianUpdated(address indexed guardian);
    event TreasuryUpdated(address indexed treasury);
    event VerifierUpdated(address indexed verifier);
    event EpochOpened(uint256 indexed epochId, uint64 depositStart, uint64 depositEnd, uint64 drawTime);
    event Deposited(uint256 indexed epochId, address indexed account, uint256 amount);
    event EpochClosed(uint256 indexed epochId, uint256 principal, uint256 shares);
    event EpochFinalized(uint256 indexed epochId, address indexed winner, uint256 prize, bytes32 randomWord);
    event EpochCancelled(uint256 indexed epochId, uint256 refundedPrincipal, uint256 treasurySurplus);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address initialOperator,
        address initialGuardian,
        address initialTreasury,
        IERC20 asset_,
        IERC4626 vault_,
        IRandomnessVerifier verifier_
    ) external initializer {
        if (
            initialOwner == address(0) || initialOperator == address(0) || initialGuardian == address(0)
                || initialTreasury == address(0) || address(asset_) == address(0) || address(vault_) == address(0)
                || address(verifier_) == address(0)
        ) revert ZeroAddress();
        if (vault_.asset() != address(asset_)) revert InvalidVaultAsset(address(asset_), vault_.asset());
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        operator = initialOperator;
        guardian = initialGuardian;
        treasury = initialTreasury;
        asset = asset_;
        vault = vault_;
        randomnessVerifier = verifier_;
        emit OperatorUpdated(initialOperator);
        emit GuardianUpdated(initialGuardian);
        emit TreasuryUpdated(initialTreasury);
        emit VerifierUpdated(address(verifier_));
    }

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    modifier onlyGuardianOrOwner() {
        _onlyGuardianOrOwner();
        _;
    }

    function _onlyOperator() internal view {
        if (msg.sender != operator && msg.sender != owner()) revert UnauthorizedOperator(msg.sender);
    }

    function _onlyGuardianOrOwner() internal view {
        if (msg.sender != guardian && msg.sender != owner()) revert UnauthorizedGuardian(msg.sender);
    }

    function epoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function userDeposit(uint256 epochId, address account) external view returns (uint256) {
        return _userDeposits[epochId][account];
    }

    function hasClaimed(uint256 epochId, address account) external view returns (bool) {
        return _claimed[epochId][account];
    }

    function participants(uint256 epochId) external view returns (address[] memory) {
        return _participants[epochId];
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorUpdated(newOperator);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setRandomnessVerifier(IRandomnessVerifier newVerifier) external onlyOwner {
        if (address(newVerifier) == address(0)) revert ZeroAddress();
        randomnessVerifier = newVerifier;
        emit VerifierUpdated(address(newVerifier));
    }

    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function openEpoch(uint64 depositEnd, uint64 drawTime) external onlyOwner whenNotPaused returns (uint256 epochId) {
        if (depositEnd <= block.timestamp || drawTime <= depositEnd) revert InvalidEpochWindow();
        if (currentEpochId != 0) {
            Epoch storage previousEpoch = _epochs[currentEpochId];
            if (previousEpoch.status != EpochStatus.Finalized && previousEpoch.status != EpochStatus.Cancelled) {
                revert PreviousEpochNotSettled(currentEpochId);
            }
        }
        epochId = currentEpochId + 1;
        currentEpochId = epochId;
        Epoch storage newEpoch = _epochs[epochId];
        newEpoch.depositStart = uint64(block.timestamp);
        newEpoch.depositEnd = depositEnd;
        newEpoch.drawTime = drawTime;
        newEpoch.status = EpochStatus.Open;
        emit EpochOpened(epochId, newEpoch.depositStart, depositEnd, drawTime);
    }

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert DepositAmountZero();
        uint256 epochId = currentEpochId;
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Open) revert InvalidEpochState(epochId, currentEpoch.status);
        if (block.timestamp >= currentEpoch.depositEnd) {
            revert DepositWindowClosed(epochId, block.timestamp, currentEpoch.depositEnd);
        }
        if (_userDeposits[epochId][msg.sender] == 0) {
            _participants[epochId].push(msg.sender);
        }
        _userDeposits[epochId][msg.sender] += amount;
        currentEpoch.totalPrincipal += amount;
        currentEpoch.remainingClaimable += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(epochId, msg.sender, amount);
    }

    function closeEpoch(uint256 epochId, uint256 minSharesOut) external onlyOperator whenNotPaused nonReentrant {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Open) revert InvalidEpochState(epochId, currentEpoch.status);
        if (block.timestamp < currentEpoch.depositEnd) {
            revert DepositWindowClosed(epochId, block.timestamp, currentEpoch.depositEnd);
        }
        if (currentEpoch.totalPrincipal == 0) revert NoParticipants(epochId);
        asset.forceApprove(address(vault), currentEpoch.totalPrincipal);
        uint256 shares = vault.deposit(currentEpoch.totalPrincipal, address(this));
        if (shares < minSharesOut) revert SlippageExceeded(minSharesOut, shares);
        currentEpoch.vaultShares = shares;
        currentEpoch.status = EpochStatus.Locked;
        emit EpochClosed(epochId, currentEpoch.totalPrincipal, shares);
    }

    function finalizeEpoch(
        uint256 epochId,
        bytes32 randomWord,
        uint256 validUntil,
        bytes calldata proof,
        uint256 minAssetsOut
    ) external onlyOperator whenNotPaused nonReentrant {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Locked) revert InvalidEpochState(epochId, currentEpoch.status);
        if (block.timestamp < currentEpoch.drawTime) revert InvalidEpochState(epochId, currentEpoch.status);
        randomnessVerifier.verify(
            IRandomnessVerifier.RandomnessRequest({
                consumer: address(this),
                chainId: block.chainid,
                epochId: epochId,
                randomWord: randomWord,
                validUntil: validUntil
            }),
            proof
        );
        uint256 balanceBefore = asset.balanceOf(address(this));
        uint256 assetsOut = vault.redeem(currentEpoch.vaultShares, address(this), address(this));
        uint256 recovered = asset.balanceOf(address(this)) - balanceBefore;
        if (assetsOut < recovered) {
            recovered = assetsOut;
        }
        if (recovered < minAssetsOut) revert SlippageExceeded(minAssetsOut, recovered);
        if (recovered < currentEpoch.totalPrincipal) {
            revert PrincipalImpaired(currentEpoch.totalPrincipal, recovered);
        }
        uint256 yieldAward = recovered - currentEpoch.totalPrincipal;
        uint256 winningCursor = uint256(randomWord) % currentEpoch.totalPrincipal;
        address winner = _selectWinner(epochId, winningCursor);
        currentEpoch.vaultShares = 0;
        currentEpoch.yieldAward = yieldAward;
        currentEpoch.remainingClaimable += yieldAward;
        currentEpoch.winner = winner;
        currentEpoch.randomWord = randomWord;
        currentEpoch.status = EpochStatus.Finalized;
        emit EpochFinalized(epochId, winner, yieldAward, randomWord);
    }

    function cancelOpenEpoch(uint256 epochId) external onlyOwner whenPaused {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Open) revert InvalidEpochState(epochId, currentEpoch.status);
        currentEpoch.status = EpochStatus.Cancelled;
        emit EpochCancelled(epochId, currentEpoch.totalPrincipal, 0);
    }

    function cancelLockedEpoch(uint256 epochId, uint256 minAssetsOut) external onlyOwner whenPaused nonReentrant {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Locked) revert InvalidEpochState(epochId, currentEpoch.status);
        uint256 balanceBefore = asset.balanceOf(address(this));
        uint256 assetsOut = vault.redeem(currentEpoch.vaultShares, address(this), address(this));
        uint256 recovered = asset.balanceOf(address(this)) - balanceBefore;
        if (assetsOut < recovered) {
            recovered = assetsOut;
        }
        if (recovered < minAssetsOut) revert SlippageExceeded(minAssetsOut, recovered);
        if (recovered < currentEpoch.totalPrincipal) {
            revert PrincipalImpaired(currentEpoch.totalPrincipal, recovered);
        }
        uint256 surplus = recovered - currentEpoch.totalPrincipal;
        currentEpoch.vaultShares = 0;
        currentEpoch.status = EpochStatus.Cancelled;
        if (surplus != 0) {
            asset.safeTransfer(treasury, surplus);
        }
        emit EpochCancelled(epochId, currentEpoch.totalPrincipal, surplus);
    }

    function claim(uint256 epochId) external nonReentrant {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.status != EpochStatus.Finalized && currentEpoch.status != EpochStatus.Cancelled) {
            revert InvalidEpochState(epochId, currentEpoch.status);
        }
        uint256 principal = _userDeposits[epochId][msg.sender];
        if (principal == 0) revert NothingToClaim(epochId, msg.sender);
        if (_claimed[epochId][msg.sender]) revert AlreadyClaimed(epochId, msg.sender);
        _claimed[epochId][msg.sender] = true;
        uint256 payout = principal;
        if (currentEpoch.status == EpochStatus.Finalized && msg.sender == currentEpoch.winner) {
            payout += currentEpoch.yieldAward;
        }
        currentEpoch.remainingClaimable -= payout;
        asset.safeTransfer(msg.sender, payout);
        emit Claimed(epochId, msg.sender, payout);
    }

    function rescueUnsupportedToken(IERC20 token, address to, uint256 amount) external onlyOwner whenPaused {
        if (address(token) == address(asset) || address(token) == address(vault)) {
            revert UnsupportedRescueToken(address(token));
        }
        token.safeTransfer(to, amount);
    }

    function previewWinner(uint256 epochId, bytes32 randomWord) external view returns (address) {
        Epoch storage currentEpoch = _epochs[epochId];
        if (currentEpoch.totalPrincipal == 0) return address(0);
        return _selectWinner(epochId, uint256(randomWord) % currentEpoch.totalPrincipal);
    }

    function _selectWinner(uint256 epochId, uint256 cursor) internal view returns (address winner) {
        address[] storage epochUsers = _participants[epochId];
        uint256 length = epochUsers.length;
        if (length == 0) revert NoParticipants(epochId);
        uint256 target = cursor + 1;
        uint256 runningTotal;
        for (uint256 i = 0; i < length; ++i) {
            runningTotal += _userDeposits[epochId][epochUsers[i]];
            if (runningTotal >= target) {
                return epochUsers[i];
            }
        }
        revert InvalidWinnerSelection(epochId, target);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
