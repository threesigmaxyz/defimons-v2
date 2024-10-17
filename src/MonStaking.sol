// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMonERC721} from "./interfaces/IMonERC721.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";
import {LiquidStakedMonster} from "./LiquidStakedMonster.sol";

// TODO - Implement bitmap for checking if user is premium on other chains 
// TODO - Create LSToken in the constructor so we'll have its address here and it will have this address there


contract MonStaking is OApp, IERC721Receiver {
    using SafeERC20 for IERC20;

    enum Multipliers {
        TOKEN_BASE,
        TOKEN_PREMIUM,
        NFT_BASE,
        NFT_PREMIUM
    }

    struct TimeInfo {
        uint256 lastUpdatedTimestamp;
        uint256 startingTimestamp;
    }

    struct UserUnstakeRequest {
        uint256 tokenAmount;
        uint256 nftAmount;
        uint256 requestTimestamp;
    }

    error MonStaking__ZeroAddress();
    error MonStaking__ZeroAmount();
    error MonStaking__ZeroChainId();
    error MonStaking__TimelockNotPassed();
    error MonStaking__InvalidTokenBaseMultiplier();
    error MonStaking__InvalidTokenPremiumMultiplier();
    error MonStaking__InvalidNftBaseMultiplier();
    error MonStaking__InvalidNftPremiumMultiplier();
    error MonStaking__InvalidMultiplierType();
    error MonStaking__InvalidTokenDecimals();
    error MonStaking__InvalidTokenId();
    error MonStaking__NotLSMContract();
    error MonStaking__ChainNotSupported();
    error MonStaking__UserAlreadyPremium();
    error MonStaking__UserNotPremium();
    error MonStaking__NotEnoughNativeTokens();
    error MonStaking__NotEnoughMonsterTokens();
    error MonStaking__CannotTotallyUnstake();

    event TokenBaseMultiplierChanged(uint256 indexed _newValue);
    event TokenPremiumMultiplierChanged(uint256 indexed _newValue);
    event NftBaseMultiplierChanged(uint256 indexed _newValue);
    event NftPremiumMultiplierChanged(uint256 indexed _newValue);
    event NewChainPinged(uint32 indexed _chainId, address indexed _user);
    event StakingBalanceUpdated(address indexed _from, address indexed _to, uint256 indexed _amount);
    event TokensStaked(address indexed _user, uint256 indexed _amount);
    event TokensUnstaked(address indexed _user, uint256 indexed _amount);
    event NftStaked(address indexed _user, uint256 indexed _tokenId);
    event ChainsUpdated(uint32[] indexed _chainIds, address indexed _user, bool indexed _isPremium);
    event PointsSynced(address indexed _user, uint256 indexed _totalPoints);

    uint256 public constant BPS = 10_000;
    uint256 public constant POINTS_DECIMALS = 1e6;
    uint256 public constant MAX_SUPPOERTED_CHAINS = 10;
    uint256 public constant TIME_LOCK_DURATION = 3 hours;

    uint256 public immutable i_crationTimestamp;
    uint256 public immutable i_premiumDuration;
    uint256 public immutable i_endPremiumTimestamp;
    address public immutable i_monsterToken;
    uint256 public immutable i_monsterTokenDecimals;
    address public immutable i_lsToken;
    uint256 public immutable i_lsTokenDecimals;
    address public immutable i_nftToken;
    uint256 public immutable i_nftMaxSupply;
    IDelegateRegistry public immutable i_delegateRegistry;

    uint256 public s_tokenBaseMultiplier;
    uint256 public s_tokenPremiumMultiplier;
    uint256 public s_nftBaseMultiplier;
    uint256 public s_nftPremiumMultiplier;

    mapping(address user => TimeInfo timeInfo) public s_userTimeInfo;
    mapping(address user => uint256 nftAmount) public s_userNftAmount;
    mapping(uint256 tokenId => address owner) public s_nftOwner;
    mapping(address user => uint256 points) public s_userPoints;
    mapping(address user => uint256 stakedTokenAmount) public s_userStakedTokenAmount;
    mapping(uint32 chainId => bytes32 otherChainStaking) public s_otherChainStakingContract;
    uint32[MAX_SUPPOERTED_CHAINS] public s_supportedChains; // this is made for saving gas
    mapping(uint32 chainId => mapping(address user => bool isPremium)) public s_isUserPremium;
    mapping(address user => UserUnstakeRequest unstakeRequest) public s_userUnstakeRequest;

    modifier onlyLSMContract() {
        if (msg.sender != i_lsToken) revert MonStaking__NotLSMContract();
        _;
    }

    modifier ifTimelockAllows() {
        if (s_userUnstakeRequest[msg.sender].requestTimestamp + TIME_LOCK_DURATION > block.timestamp) {
            revert MonStaking__TimelockNotPassed();
        }
        _;
    }

    constructor(
        address _endpoint,
        address _delegated,
        uint256 _premiumDuration,
        address _monsterToken,
        address _nftToken,
        uint256 _tokenBaseMultiplier,
        uint256 _tokenPremiumMultiplier,
        uint256 _nftBaseMultiplier,
        uint256 _nftPremiumMultiplier,
        address _delegateRegistry,
        address _marketPlace,
        address _operatorRole,
        address _defaultAdmin
    ) OApp(_endpoint, _delegated) Ownable(_delegated) {
        if (
            _monsterToken == address(0) ||  _nftToken == address(0)
                || _delegateRegistry == address(0)
        ) revert MonStaking__ZeroAddress();
        if (_premiumDuration == 0) revert MonStaking__ZeroAmount();
        if (_tokenBaseMultiplier == 0 || _tokenBaseMultiplier >= _tokenPremiumMultiplier) {
            revert MonStaking__InvalidTokenBaseMultiplier();
        }
        if (_tokenPremiumMultiplier == 0) revert MonStaking__InvalidTokenPremiumMultiplier();
        if (_nftBaseMultiplier == 0 || _nftBaseMultiplier >= _nftPremiumMultiplier) {
            revert MonStaking__InvalidNftBaseMultiplier();
        }
        if (_nftPremiumMultiplier == 0) revert MonStaking__InvalidNftPremiumMultiplier();

        i_crationTimestamp = block.timestamp;
        i_premiumDuration = _premiumDuration;
        i_endPremiumTimestamp = i_crationTimestamp + i_premiumDuration;
        i_monsterToken = _monsterToken;
        i_monsterTokenDecimals = IERC20Metadata(_monsterToken).decimals();
        if (i_monsterTokenDecimals == 0) revert MonStaking__InvalidTokenDecimals();
        if (i_lsTokenDecimals == 0) revert MonStaking__InvalidTokenDecimals();
        i_nftToken = _nftToken;
        i_nftMaxSupply = IMonERC721(_nftToken).maxSupply();
        i_delegateRegistry = IDelegateRegistry(_delegateRegistry);

        s_tokenBaseMultiplier = _tokenBaseMultiplier;
        s_tokenPremiumMultiplier = _tokenPremiumMultiplier;
        s_nftBaseMultiplier = _nftBaseMultiplier;
        s_nftPremiumMultiplier = _nftPremiumMultiplier;

        i_lsToken = address(new LiquidStakedMonster(_operatorRole, _defaultAdmin, _marketPlace));
    }

    function stakeTokens(uint256 _amount) external payable {

        if (_amount == 0) revert MonStaking__ZeroAmount();

        bool isUserAlreadyPremium = _isUserPremium(s_userTimeInfo[msg.sender].startingTimestamp);

        _updateUserState(msg.sender);

        s_userStakedTokenAmount[msg.sender] += _amount;
        
        if (!isUserAlreadyPremium && block.timestamp <= i_endPremiumTimestamp) _updateOtherChains(msg.sender, true);

        IERC20(i_monsterToken).safeTransferFrom(msg.sender, address(this), _amount);

        LiquidStakedMonster(i_lsToken).mint(msg.sender, _amount);

        emit TokensStaked(msg.sender, _amount);
    }

    function stakeNft(uint256 _tokenId) external payable {

        if(_tokenId == 0 || _tokenId > i_nftMaxSupply) revert MonStaking__InvalidTokenId();

        bool isUserAlreadyPremium = _isUserPremium(s_userTimeInfo[msg.sender].startingTimestamp);

        _updateUserState(msg.sender);

        s_userNftAmount[msg.sender] += 1;
        s_nftOwner[_tokenId] = msg.sender;

        if (!isUserAlreadyPremium && block.timestamp <= i_endPremiumTimestamp) _updateOtherChains(msg.sender, true);

        IERC721(i_nftToken).safeTransferFrom(msg.sender, address(this), _tokenId);

        emit NftStaked(msg.sender, _tokenId);
    }

    // TODO - if like this remove payable
    function unstakeTokens(uint256 _amount) external payable {

        uint256 userTokenBalance = s_userStakedTokenAmount[msg.sender];

        if (_amount == 0) revert MonStaking__ZeroAmount();
        if (_amount > userTokenBalance) revert MonStaking__NotEnoughMonsterTokens();
        if (_amount == userTokenBalance && s_userNftAmount[msg.sender] == 0) revert MonStaking__CannotTotallyUnstake();

        _updateUserState(msg.sender);
        
        s_userStakedTokenAmount[msg.sender] -= _amount;

        LiquidStakedMonster(i_lsToken).burn(msg.sender, _amount);

        emit TokensUnstaked(msg.sender, _amount);
    }

    // TODO - if like this remove payable
    function unstakeNft(uint256 _tokenId) external payable {

        uint256 userNftBalance = s_userNftAmount[msg.sender];

        if(_tokenId == 0 || _tokenId > i_nftMaxSupply) revert MonStaking__InvalidTokenId();
        if(userNftBalance == 0) revert MonStaking__ZeroAmount();
        if(userNftBalance == 1 && s_userStakedTokenAmount[msg.sender] == 0) revert MonStaking__CannotTotallyUnstake();

        _updateUserState(msg.sender);

        s_userNftAmount[msg.sender] -= 1;
        delete s_nftOwner[_tokenId];

        IERC721(i_nftToken).safeTransferFrom(address(this), msg.sender, _tokenId);

        emit NftStaked(msg.sender, _tokenId);
    }

    function requireUnstakeAll() external payable {}

    function claimUnstakedAssets() external ifTimelockAllows {}

    function updateStakingBalance(address _from, address _to, uint256 _amount) external payable onlyLSMContract {

        if (_from == address(0) || _to == address(0)) revert MonStaking__ZeroAddress();
        if (_amount == 0) revert MonStaking__ZeroAmount();

        _updateUserState(_from);
        _updateUserState(_to);

        s_userStakedTokenAmount[_from] -= _amount;
        s_userStakedTokenAmount[_to] += _amount;

        // TODO - remove variables
        uint256 fromTokenBalance = s_userStakedTokenAmount[_from];
        uint256 fromNftBalance = s_userNftAmount[_from];
        bool isFromPremium = _isUserPremium(s_userTimeInfo[_from].startingTimestamp);

        if (fromTokenBalance == 0 && fromNftBalance == 0) {
            _clearUserTimeInfo(_from);

            if(isFromPremium) {

                _updateOtherChains(_from, false);
            }

        }

        emit StakingBalanceUpdated(_from, _to, _amount);
    }

    // made if we are premium here and we want to signal it to a newly deployed contract on other chain
    function pingNewChainContract(uint32 _chainId) external payable {

        if (_chainId == 0) revert MonStaking__ZeroChainId();
        if (s_otherChainStakingContract[_chainId] == bytes32(0)) revert MonStaking__ChainNotSupported();
        if (s_isUserPremium[_chainId][msg.sender]) revert MonStaking__UserAlreadyPremium();
        if (!_isUserPremium(s_userTimeInfo[msg.sender].startingTimestamp)) revert MonStaking__UserNotPremium();

        bytes memory message = abi.encode(msg.sender, true);

        bool payInLzToken = msg.value == 0;

        MessagingFee memory _fee = _quote(_chainId, message, "", payInLzToken);


        _lzSend(_chainId, message, "", _fee, msg.sender);

        emit NewChainPinged(_chainId, msg.sender);
    }

    function syncPoints() external {
        _updateUserState(msg.sender);

        emit PointsSynced(msg.sender, s_userPoints[msg.sender]);
    }

    function setMultiplier(Multipliers _multiplierType, uint256 _value) external onlyOwner {
        if (_value == 0) revert MonStaking__ZeroAmount();

        if (_multiplierType == Multipliers.TOKEN_BASE) {
            if (_value >= s_tokenPremiumMultiplier) revert MonStaking__InvalidTokenBaseMultiplier();

            s_tokenBaseMultiplier = _value;
            emit TokenBaseMultiplierChanged(_value);
        } else if (_multiplierType == Multipliers.TOKEN_PREMIUM) {
            if (_value <= s_tokenBaseMultiplier) revert MonStaking__InvalidTokenPremiumMultiplier();

            s_tokenPremiumMultiplier = _value;
            emit TokenPremiumMultiplierChanged(_value);
        } else if (_multiplierType == Multipliers.NFT_BASE) {
            if (_value >= s_nftPremiumMultiplier) revert MonStaking__InvalidNftBaseMultiplier();

            s_nftBaseMultiplier = _value;
            emit NftBaseMultiplierChanged(_value);
        } else if (_multiplierType == Multipliers.NFT_PREMIUM) {
            if (_value <= s_nftBaseMultiplier) revert MonStaking__InvalidNftPremiumMultiplier();

            s_nftPremiumMultiplier = _value;
            emit NftPremiumMultiplierChanged(_value);
        } else {
            revert MonStaking__InvalidMultiplierType();
        }
    }

    function onERC721Received(address, /*_operator*/ address, /*_from*/ uint256, /*_tokenId*/ bytes calldata /*_data*/ )
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function _batchQuote(
        uint32[] memory _dstEids,
        bytes memory _message,
        bytes calldata _extraSendOptions,
        bool _payInLzToken
    ) public view returns (MessagingFee memory totalFee) {
        for (uint i = 0; i < _dstEids.length; i++) {
            MessagingFee memory fee = _quote(_dstEids[i], _message, options, _payInLzToken);
            totalFee.nativeFee += fee.nativeFee;
            totalFee.lzTokenFee += fee.lzTokenFee;
        }
    }


    function _updateUserState(address _user) internal {
        uint256 userTokenBalance = s_userStakedTokenAmount[_user];
        uint256 userNftBalance = s_userNftAmount[_user];
        TimeInfo memory userTimeInfo = s_userTimeInfo[_user];

        _updateUserPoints(userTokenBalance, userNftBalance, userTimeInfo, _user);
        _updateUserTimeInfo();
    }

    function _updateUserPoints(
        uint256 _userTokenBalance,
        uint256 _userNftBalance,
        TimeInfo memory _userTimeInfo,
        address _user
    ) internal {
        uint256 currentTimestamp = block.timestamp;
        // Gas efficient because if first case evaluates to true, the second one is not checked - maybe a better way to do this
        bool isPremium = _isUserPremium(_userTimeInfo.startingTimestamp) || _isUserPremiumOnOtherChains(_user);
        uint256 tokenPoints = _calculateTokenPoints(_userTokenBalance, _userTimeInfo.lastUpdatedTimestamp, currentTimestamp, isPremium);
        uint256 nftPoints = _calculateNftPoints(_userNftBalance, _userTimeInfo.lastUpdatedTimestamp, currentTimestamp, isPremium);
        s_userPoints[_user] += tokenPoints + nftPoints;
    }

    function _updateUserTimeInfo() internal {
        s_userTimeInfo[msg.sender].lastUpdatedTimestamp = block.timestamp;
        if(s_userTimeInfo[msg.sender].startingTimestamp == 0) {
            s_userTimeInfo[msg.sender].startingTimestamp = block.timestamp;
        }
    }

    function _clearUserTimeInfo(address _user) internal {
        delete s_userTimeInfo[_user];
    }

    function _calculateTokenPoints(
        uint256 _tokenAmount,
        uint256 _lastTimestamp,
        uint256 _currentTimestamp,
        bool _isPremium
    ) internal view returns (uint256) {
        uint256 multiplier = _isPremium ? s_tokenPremiumMultiplier : s_tokenBaseMultiplier;
        uint256 timeDiff = _currentTimestamp - _lastTimestamp;
        uint256 points = _tokenAmount * multiplier * timeDiff;
        return _enforcePointDecimals(points) / i_monsterTokenDecimals / BPS;
    }

    function _calculateNftPoints(uint256 _nftAmount, uint256 _lastTimestamp, uint256 _currentTimestamp, bool _isPremium)
        internal
        view
        returns (uint256)
    {
        uint256 multiplier = _isPremium ? s_nftPremiumMultiplier : s_nftBaseMultiplier;
        uint256 timeDiff = _currentTimestamp - _lastTimestamp;
        uint256 points = _nftAmount * multiplier * timeDiff;
        return _enforcePointDecimals(points) / BPS;
    }

    function _enforcePointDecimals(uint256 _points) internal pure returns (uint256) {
        return _points * POINTS_DECIMALS;
    }

    function _isUserPremium(uint256 _startTimestamp) internal view returns (bool) {
        return _startTimestamp <= i_endPremiumTimestamp && _startTimestamp >= i_crationTimestamp;
    }

    function _isUserPremiumOnOtherChains(address _user) internal view returns (bool) {
        for (uint256 i = 0; i < MAX_SUPPOERTED_CHAINS; i++) {
            uint32 chainId = s_supportedChains[i];
            if(s_isUserPremium[chainId][_user]) return true;
        }
        return false;
    }

    function _updateOtherChains(address _user, bool _isPremium) internal {

        uint256 chainsLength = s_supportedChains.length;

        MessagingFee memory totalFee = _batchQuote(s_supportedChains, abi.encode(_user, _isPremium), "", msg.value <= 0);

        if(msg.value > 0 && msg.value < totalFee.nativeFee) revert MonStaking__NotEnoughNativeTokens();

        uint256 totalNativeFeeUsed = 0;
        uint256 remainingValue = msg.value;

        for (uint256 i = 0; i < chainsLength; i++) {
            uint32 chainId = s_supportedChains[i];
            MessagingFee memory fee = _quote(chainId, abi.encode(_user, _isPremium), "", msg.value <= 0);

            if(msg.value > 0) {
                if(remainingValue < fee.nativeFee) revert MonStaking__NotEnoughNativeTokens();
                remainingValue -= fee.nativeFee;
            }

            totalNativeFeeUsed += fee.nativeFee;

            _lzSend(chainId, abi.encode(_user, _isPremium), "", fee, _user);
        }

        emit ChainsUpdated(s_supportedChains, _user, _isPremium);
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {}
}
