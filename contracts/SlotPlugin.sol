// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import { IEntropyConsumer } from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import { IEntropy } from "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";

interface IBerachainRewardVaultFactory {
    function createRewardVault(address _vaultToken) external returns (address);
}

interface IRewardVault {
    function stake(uint256 amount) external;
    function getReward(address account, address recipient) external returns (uint256);
}

interface IBGT {
    function unboostedBalanceOf(address account) external view returns (uint256);
    function redeem(address receiver, uint256 amount) external;
}

interface IWBERA {
    function deposit() external payable;
}

contract VaultToken is ERC20, Ownable {

    constructor() ERC20("HighRollersCub", "HighRollersCub") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

contract Slot is ReentrancyGuard, Ownable, IEntropyConsumer {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /*----------  CONSTANTS  --------------------------------------------*/

    uint256 public constant DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant BASIS_POINTS = 10_000;
    address public constant BGT = 0x656b95E550C07a9ffe548bd4085c72418Ceb1dba;

    /*----------  STATE VARIABLES  --------------------------------------*/

    IEntropy public entropy;

    address public immutable vaultToken;
    address public immutable rewardVault;

    address public treasury;
    address public developer;
    address public incentives;

    bool public initialized = false;

    uint256 public maxIndex = 100;

    mapping(uint256 => uint256) public index_Rate;
    mapping(uint64 => address) public sequence_Account;

    uint256 public price = 0.01 ether;

    /*----------  ERRORS ------------------------------------------------*/

    error Slot__InvalidZeroAddress();
    error Slot__NotInitialized();
    error Slot__NotDeveloper();
    error Slot__InvalidSequence();
    error Slot__InsufficientPrice();
    error Slot__InsufficientFee();
    error Slot__InvalidArrayLength();
    error Slot__InvalidRange();
    error Slot__InvalidRate();
    error Slot__AlreadyInitialized();

    /*----------  EVENTS ------------------------------------------------*/

    event Slot__Initialized();
    event Slot__PlayRequest(uint64 sequenceNumber, address account);
    event Slot__PlayResult(address account, uint256 index, uint256 rate, uint256 reward);
    event Slot__Distributed(uint256 incentivesAmount, uint256 developerAmount, uint256 treasuryAmount);
    event Slot__PriceSet(uint256 price);
    event Slot__TreasurySet(address treasury);
    event Slot__DeveloperSet(address developer);
    event Slot__IncentivesSet(address incentives);
    event Slot__IndexSet(uint256 index, uint256 rate);
    event Slot__MaxIndexSet(uint256 maxIndex);

    /*----------  MODIFIERS  --------------------------------------------*/

    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert Slot__InvalidZeroAddress();
        _;
    }

    /*----------  FUNCTIONS  --------------------------------------------*/

    constructor(
        address _vaultFactory,
        address _entropy
    ) {
        treasury = msg.sender;
        developer = msg.sender;
        incentives = msg.sender;
        entropy = IEntropy(_entropy);
        vaultToken = address(new VaultToken());
        rewardVault = IBerachainRewardVaultFactory(_vaultFactory).createRewardVault(address(vaultToken));
    }

    receive() external payable {}

    function initialize() external {
        if (initialized) revert Slot__AlreadyInitialized();
        initialized = true;

        VaultToken(vaultToken).mint(address(this), DEPOSIT_AMOUNT);
        IERC20(vaultToken).safeApprove(rewardVault, 0);
        IERC20(vaultToken).safeApprove(rewardVault, DEPOSIT_AMOUNT);
        IRewardVault(rewardVault).stake(DEPOSIT_AMOUNT);

        emit Slot__Initialized();
    }

    function play(address account, bytes32 userRandomNumber) external payable nonReentrant {
        if (!initialized) revert Slot__NotInitialized();
        if (account == address(0)) revert Slot__InvalidZeroAddress();
        if (msg.value < price) revert Slot__InsufficientPrice();

        uint256 bgtReward = IRewardVault(rewardVault).getReward(address(this), address(this));
        if (bgtReward > 0) IBGT(BGT).redeem(address(this), bgtReward);

        if (address(entropy) != address(0)) {
            address entropyProvider = entropy.getDefaultProvider();
            uint256 fee = entropy.getFee(entropyProvider);
            if (msg.value < price + fee) revert Slot__InsufficientFee();
            uint64 sequenceNumber = entropy.requestWithCallback{value: fee}(entropyProvider, userRandomNumber);
            sequence_Account[sequenceNumber] = account;
            emit Slot__PlayRequest(sequenceNumber, account);
        } else {
            userRandomNumber = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender));
            mockCallback(account, userRandomNumber);
            emit Slot__PlayRequest(0, account);
        }
    }

    function distribute() external {
        uint256 balance = address(this).balance;
        uint256 incentivesAmount = balance * 80 / 100;
        uint256 developerAmount = balance * 10 / 100;
        uint256 treasuryAmount = balance - incentivesAmount - developerAmount;

        payable(incentives).sendValue(incentivesAmount);
        payable(developer).sendValue(developerAmount);
        payable(treasury).sendValue(treasuryAmount);

        emit Slot__Distributed(incentivesAmount, developerAmount, treasuryAmount);
    }

    /*----------  RESTRICTED FUNCTIONS  ---------------------------------*/

    function entropyCallback(
        uint64 sequenceNumber,
        address,
        bytes32 randomNumber
    ) internal override {
        address account = sequence_Account[sequenceNumber];
        if (account == address(0)) revert Slot__InvalidSequence();

        uint256 randomIndex = uint256(randomNumber) % maxIndex;
        uint256 balance = address(this).balance;
        uint256 rate = index_Rate[randomIndex];
        uint256 reward = (balance * rate) / BASIS_POINTS;

        if (reward > 0) payable(account).transfer(reward);

        delete sequence_Account[sequenceNumber];

        emit Slot__PlayResult(account, randomIndex, rate, reward);
    }

    function mockCallback(address account, bytes32 randomNumber) internal {
        uint256 randomIndex = uint256(randomNumber) % maxIndex;
        uint256 balance = address(this).balance;
        uint256 rate = index_Rate[randomIndex];
        uint256 reward = (balance * rate) / BASIS_POINTS;

        if (reward > 0) payable(account).transfer(reward);

        emit Slot__PlayResult(account, randomIndex, rate, reward);
    }

    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
        emit Slot__PriceSet(price);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit Slot__TreasurySet(treasury);
    }

    function setDeveloper(address _developer) external nonZeroAddress(_developer) {
        if (msg.sender != developer) revert Slot__NotDeveloper();
        developer = _developer;
        emit Slot__DeveloperSet(developer);
    }

    function setIncentives(address _incentives) external onlyOwner nonZeroAddress(_incentives) {
        incentives = _incentives;
        emit Slot__IncentivesSet(incentives);
    }

    function setIndex(uint256 index, uint256 rate) external onlyOwner {
        if (rate >= BASIS_POINTS) revert Slot__InvalidRate();
        index_Rate[index] = rate;
        emit Slot__IndexSet(index, rate);
    }

    function setIndexes(uint256[] calldata indexes, uint256[] calldata rates) external onlyOwner {
        if (indexes.length != rates.length) revert Slot__InvalidArrayLength();
        for (uint256 i = 0; i < indexes.length; i++) {
            if (rates[i] >= BASIS_POINTS) revert Slot__InvalidRate();
            index_Rate[indexes[i]] = rates[i];
            emit Slot__IndexSet(indexes[i], rates[i]);
        }
    }

    function setIndexRange(uint256 startIndex, uint256 endIndex, uint256 rate) external onlyOwner {
        if (startIndex > endIndex) revert Slot__InvalidRange();
        if (rate >= BASIS_POINTS) revert Slot__InvalidRate();

        for (uint256 i = startIndex; i <= endIndex; i++) {
            index_Rate[i] = rate;
            emit Slot__IndexSet(i, rate);
        }
    }

    function setMaxIndex(uint256 _maxIndex) external onlyOwner {
        maxIndex = _maxIndex;
        emit Slot__MaxIndexSet(_maxIndex);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

}