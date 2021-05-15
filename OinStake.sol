// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "./Math.sol";
import "./SafeMath.sol";
import "./IERC20.sol";
import "./Owned.sol";
import "./IDparam.sol";
import "./WhiteList.sol";

interface IOracle {
    function val() external returns (uint256);

    function poke(uint256 price) external;

    function peek() external;
}

interface FeeOracle {
    function val() external returns (uint256);
}

interface IESM {
    function isStakePaused() external view returns (bool);

    function isRedeemPaused() external view returns (bool);

    function isClosed() external view returns (bool);

    function time() external view returns (uint256);
}

interface ICoin {
    function burn(address account, uint256 amount) external;

    function mint(address account, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);
}

contract OinStake is Owned, WhiteList {
    using Math for uint256;
    using SafeMath for uint256;

    /**
     * @notice reward pools state
     * @param index Accumulated earnings index by staker
     * @param reward Accumulative reward
     */
    struct StakerState {
        uint256 index;
        uint256 reward;
    }

    /**
     * @notice fundsFee array
     * @param staker fundsFee
     * @param block update blockNumber
     */

    struct FundsFeeState {
        uint256 fundsFee;
        uint256 block;
    }

    /**
     * @notice reward array
     * @param coinAddress The address of reward coin
     * @param rewardTotal The total number or reward
     * @param rewardSpeed The speed of reward delivery
     * @param initialIndex Inital index
     * @param blockNumber The block number
     * @param doubleScale Amplification factor
     * @param coin Inject reward coin
     */
    struct RewardCoin {
        address coinAddress;
        uint256 rewardTotal;
        uint256 rewardSpeed;
        uint256 initialIndex;
        uint256 index;
        uint256 blockNumber;
        uint256 doubleScale;
        IERC20 coin;
    }

    RewardCoin[] public rewardCoins;

    /// @notice All staker-instances state
    mapping(address => StakerState[]) public stakerStateArray;

    /// @notice All fundsFee state
    mapping(address => FundsFeeState) public fundsFeeStates;

    mapping(address => uint256) public rewardCoinIndex;
    /// @notice The amount by staker with token
    mapping(address => uint256) public tokens;
    ///  The amount by staker with coin
    mapping(address => uint256) public coins;
    ///  The amount by staker with cToken
    mapping(address => uint256) public cTokens;
    ///  The amount by staker with feeTokens
    mapping(address => uint256) public feeTokens;
    ///@notice determines whether the user initializes the currency
    mapping(address => bool) private isOrNot;
    /// @notice The total amount of out-coin in sys
    uint256 public totalCoin;
    /// @notice The total amount of stake-token in sys
    uint256 public totalToken;
    /// @notice The total amount of totalCToken in sys
    uint256 public totalCToken;

    /// @notice Cumulative  service fee.
    uint256 private sFee;
    uint256 private pmFee;
    address private pmFeeHolder = 0x1CFC820F300103fC58a8804c221846fD25eC32D5;
    uint256 constant ONE = 10**8;
    address constant blackhole = 0x188407eeD7B1bb203dEd6801875C0B5Cb1027053;

    /// @notice Dparam address
    IDparam params;
    /// @notice Oracle address
    IOracle orcl;
    /// @notice FundsFee Oracle address
    FeeOracle feeOrcl;
    /// @notice Esm address
    IESM esm;
    /// @notice Coin address
    ICoin coin;
    /// @notice cToken address
    ICoin cToken;
    /// @notice Token address
    IERC20 token;
    /// @notice feeToken address
    IERC20 feeToken;

    /// @notice Setup Oracle address success
    event SetupOracle(address orcl);
    /// @notice Setup FundsFee Oracle address success
    event SetupFeeOracle(address feeOrcl);
    /// @notice Setup Dparam address success
    event SetupParam(address param);
    /// @notice Setup Esm address success
    event SetupEsm(address esm);
    /// @notice Setup Token&Coin address success
    event SetupCoin(
        address token,
        address coin,
        address cToken,
        address feeToken
    );
    /// @notice Stake success
    event StakeEvent(uint256 token, uint256 coin);
    /// @notice redeem success
    event RedeemEvent(uint256 token, uint256 move, uint256 fee, uint256 coin);
    /// @notice Update index success
    event IndexUpdate(uint256 delt, uint256 block, uint256 index);
    /// @notice ClaimToken success
    event ClaimToken(address holder, uint256 value, address coinAddress);
    /// @notice InjectReward success
    event InjectReward(uint256 amount, address coinAddress);
    /// @notice ExtractReward success
    event ExtractReward(address reciver, uint256 amount, address coinAddress);

    /**
     * @notice Construct a new OinStake, owner by msg.sender
  
     */
    constructor(
        address _esm,
        address _param,
        address _orcl,
        address _feeOrcl
    ) public Owned(msg.sender) {
        params = IDparam(_param);
        orcl = IOracle(_orcl);
        esm = IESM(_esm);
        feeOrcl = FeeOracle(_feeOrcl);
        InitRewardCoin();
    }

    modifier notClosed() {
        require(!esm.isClosed(), "System closed");
        _;
    }

    // /**
    //  * @notice reset Dparams address.
    //  * @param _params Configuration dynamic params contract address
    //  */
    // function setupParams(address _params) public onlyWhiter {
    //     params = IDparam(_params);
    //     emit SetupParam(_params);
    // }

    // /**
    //  * @notice reset Oracle address.
    //  * @param _orcl Configuration Oracle contract address
    //  */
    // function setupOracle(address _orcl) public onlyWhiter {
    //     orcl = IOracle(_orcl);
    //     emit SetupOracle(_orcl);
    // }

    // /**
    //  * @notice reset FeeOracle address.
    //  * @param _feeOrcl Configuration FeeOracle contract address
    //  */
    // function setupFeeOracle(address _feeOrcl) public onlyWhiter {
    //     feeOrcl = FeeOracle(_feeOrcl);
    //     emit SetupFeeOracle(_feeOrcl);
    // }

    // /**
    //  * @notice reset Esm address.
    //  * @param _esm Configuration Esm contract address
    //  */
    // function setupEsm(address _esm) public onlyWhiter {
    //     esm = IESM(_esm);
    //     emit SetupEsm(_esm);
    // }

    /**
     * @notice get Dparam address.
     * @return Dparam contract address
     */
    function getParamsAddr() public view returns (address) {
        return address(params);
    }

    /**
     * @notice get Oracle address.
     * @return Oracle contract address
     */
    function getOracleAddr() public view returns (address) {
        return address(orcl);
    }

    /**
     * @notice get FeeOracle address.
     * @return FeeOracle contract address
     */
    function getFeeOracleAddr() public view returns (address) {
        return address(feeOrcl);
    }

    /**
     * @notice get Esm address.
     * @return Esm contract address
     */
    function getEsmAddr() public view returns (address) {
        return address(esm);
    }

    /**
     * @notice get token of staking address.
     * @return ERC20 address
     */
    function getCoinAddress() public view returns (address) {
        return address(coin);
    }

    /**
     * @notice get StableToken address.
     * @return ERC20 address
     */
    function getTokenAddress() public view returns (address) {
        return address(token);
    }

    /**
     * @notice get cToken address.
     * @return ERC20 address
     */
    function getCTokenAddress() public view returns (address) {
        return address(cToken);
    }

    /**
     * @notice get feeToken address.
     * @return ERC20 address
     */
    function getFeeTokenAddress() public view returns (address) {
        return address(feeToken);
    }

    /**
     * @notice inject token address & coin address only once.
     * @param _token token address
     * @param _coin coin address
     * @param _cToken cToken address
     */
    function setup(
        address _token,
        address _coin,
        address _cToken,
        address _feeToken
    ) public onlyWhiter {
        require(
            address(token) == address(0) &&
                address(coin) == address(0) &&
                address(cToken) == address(0),
            "setuped yet."
        );
        token = IERC20(_token);
        coin = ICoin(_coin);
        cToken = ICoin(_cToken);
        feeToken = IERC20(_feeToken);
        emit SetupCoin(_token, _coin, _cToken, _feeToken);
    }

    /**
     * @notice Get the number of debt by the `account`
     * @param account token address
     * @return (tokenAmount,coinAmount)
     */
    function debtOf(address account) public view returns (uint256, uint256) {
        return (tokens[account], coins[account]);
    }

    /**
     * @notice Determine whether the current pledge rate reaches the pledge rate
     * @param staker token address
     */
    function _judgePledgeRate(address staker) internal returns (bool) {
        if (coins[staker] > 0) {
            return
                tokens[staker].mul(orcl.val()).div(coins[staker]) >=
                params.cost().mul(1e8);
        }
    }

    /**
     *@notice Claim the redundant Oin
     *@param staker token address
     */
    function claimOin(address staker) public notClosed {
        address from = msg.sender;
        require(
            _judgePledgeRate(from),
            "The current pledge rate does not meet the system pledge rate requirements"
        );
        //Calculation of funds amount 计算用户稳定费用
        uint256 fundsTokenAmount = _getFundsFee(staker);
        //Calculation of feeToken Amount 计算应付手续费的数量
        uint256 feeTokenAmount =
            fundsTokenAmount.mul(orcl.val()).div(feeOrcl.val());
        //判断用户稳定费余额
        require(
            feeToken.balanceOf(from) >= feeTokenAmount,
            "Insufficient balance of stability token in current account"
        );

        //计算可以提取的OIN
        uint256 redundantOin =
            orcl
                .val()
                .mul(tokens[from])
                .div(1e8)
                .sub(coins[from].mul(params.cost()))
                .mul(1e8)
                .div(orcl.val());

        require(
            redundantOin > 0,
            "There are currently no OIN tokens available to collect"
        );
        //用户有多少cOin可以提取多少多出来的OIN
        if (redundantOin <= cToken.balanceOf(from)) {
            redundantOin = cToken.balanceOf(from);
        }
        feeToken.transferFrom(staker, pmFeeHolder, feeTokenAmount);
        token.transfer(staker, redundantOin);
        cToken.burn(from, redundantOin);

        tokens[from] = tokens[from].sub(redundantOin);
        cTokens[from] = cTokens[from].sub(redundantOin);

        totalToken = totalToken.sub(redundantOin);
        totalCToken = totalCToken.sub(redundantOin);

        uint256 blockNumber = getBlockNumber();
        if (fundsFeeStates[staker].fundsFee <= fundsTokenAmount) {
            fundsFeeStates[staker].fundsFee = 0;
        } else {
            fundsFeeStates[staker].fundsFee =
                fundsFeeStates[staker].fundsFee -
                fundsTokenAmount;
        }
        fundsFeeStates[staker].block = blockNumber;
    }

    /**
     *@notice Claim the redundant USDO
     *@param staker token address
     */
    function claimUSDO(address staker) public notClosed {
        address from = msg.sender;
        require(
            _judgePledgeRate(from),
            "The current pledge rate does not meet the system pledge rate requirements"
        );
        uint256 blockNumber = getBlockNumber();
        uint256 redundantUSDO =
            orcl.val().mul(tokens[from]).div(params.cost()).div(1e8).sub(
                coins[from]
            );
        require(
            redundantUSDO > 0,
            "There are currently no USDO tokens available to collect"
        );
        coin.mint(staker, redundantUSDO);
        coins[from] = coins[from].add(redundantUSDO);
        totalCoin = totalCoin.add(redundantUSDO);
        fundsFeeStates[from].fundsFee = _getFundsFee(from);
        fundsFeeStates[from].block = blockNumber;
    }

    /**
     * @notice Get the number of debt by the `account`
     * @param coinAmount The amount that staker want to get stableToken
     * @return The amount that staker want to transfer token.
     */
    function getInputToken(uint256 coinAmount)
        public
        view
        returns (uint256 tokenAmount)
    {
        tokenAmount = coinAmount.mul(params.stakeRate()).div(1e8);
    }

    /**
     * @notice Calculate fundsfee
     * @param  staker token address
     * @return The amount of fundsfee that staker need to pay.
     */

    function _getFundsFee(address staker)
        internal
        view
        returns (uint256 value)
    {
        FundsFeeState storage FundsFeeState = fundsFeeStates[staker];
        uint256 fundsRate = params.fundsRate();
        uint256 blockNumber = getBlockNumber();
        uint256 deltBlock = blockNumber.sub(fundsFeeStates[staker].block);
        uint256 fundsTokenVal =
            (coins[staker].mul(params.fundsRate().mul(deltBlock)))
                .mul(params.stakeRate())
                .div(1000 * 2102400 * 1e8);
        uint256 fundsTokenAmount =
            fundsTokenVal.add(fundsFeeStates[staker].fundsFee);
        return fundsTokenAmount;
    }

    /**
     * @notice Get User fundsfee
     * @param  staker token address
     * @return The amount of fundsfee that staker need to pay.
     */
    function getFundsFee(address staker) public view returns (uint256 value) {
        return _getFundsFee(staker);
    }

    /**
     * @notice Normally redeem anyAmount internal
     * @param coinAmount The number of coin will be staking
     */
    function stake(uint256 coinAmount) external notClosed {
        require(!esm.isStakePaused(), "Stake paused");
        require(coinAmount > 0, "The quantity is less than the minimum");
        require(orcl.val() > 0, "Oracle price not initialized.");
        require(params.isNormal(orcl.val()), "Oin's price is too low.");
        require(
            params.isUpperLimit(totalCoin),
            "The total amount of pledge in the current system has reached the upper limit."
        );

        address from = msg.sender;
        uint256 tokenAmount = getInputToken(coinAmount);

        //判断用户是否首次质押 1.首次质押 初始化用户稳定费结构体 2.非首次质押 更新区块号与用户应缴稳定费
        uint256 blockNumber = getBlockNumber();
        if (coins[from] == 0) {
            fundsFeeStates[from].block = blockNumber;
            fundsFeeStates[from].fundsFee = 0;
        } else {
            fundsFeeStates[from].fundsFee = _getFundsFee(from);
            fundsFeeStates[from].block = blockNumber;
        }

        //可能会出现负数
        if (!_judgePledgeRate(from) && coins[from] > 0) {
            coinAmount = coinAmount.sub(
                coins[from].sub(
                    orcl.val().mul(tokens[from]).div(params.cost()).div(1e8)
                )
            );
        }

        accuredToken(from);
        token.transferFrom(from, address(this), tokenAmount);

        coin.mint(from, coinAmount);
        cToken.mint(from, tokenAmount);

        totalCoin = totalCoin.add(coinAmount);
        totalToken = totalToken.add(tokenAmount);
        totalCToken = totalCToken.add(tokenAmount);
        coins[from] = coins[from].add(coinAmount);
        tokens[from] = tokens[from].add(tokenAmount);
        cTokens[from] = cTokens[from].add(tokenAmount);

        emit StakeEvent(tokenAmount, coinAmount);
    }

    /**
     * @notice Normally redeem anyAmount internal
     * @param coinAmount The number of coin will be redeemed
     * @param receiver Address of receiving
     */
    function _normalRedeem(uint256 coinAmount, address receiver)
        internal
        notClosed
    {
        require(!esm.isRedeemPaused(), "Redeem paused");
        address staker = msg.sender;
        require(coins[staker] > 0, "No collateral");
        require(coinAmount > 0, "The quantity is less than zero");
        require(coinAmount <= coins[staker], "input amount overflow");

        uint256 coinVal;
        uint256 tokenAmount;
        accuredToken(staker);

        //Calculation of funds amount 计算用户稳定费用
        uint256 fundsTokenAmount = _getFundsFee(staker);
        //Calculation of feeToken Amount 计算应付手续费的数量
        uint256 feeTokenAmount =
            fundsTokenAmount.mul(orcl.val()).div(feeOrcl.val());
        //判断用户稳定费余额
        require(
            feeToken.balanceOf(receiver) >= feeTokenAmount,
            "Insufficient balance of stability token in current account"
        );
        //判断用户质押率
        if (!_judgePledgeRate(staker)) {
            coinVal = orcl.val().mul(tokens[receiver]).div(params.cost()).div(
                1e8
            );
            tokenAmount = coinVal.mul(tokens[receiver]).div(coins[receiver]);
        } else {
            tokenAmount = coinAmount.mul(tokens[receiver]).div(coins[receiver]);
        }

        if (cToken.balanceOf(staker) < tokenAmount) {
            tokenAmount = cToken.balanceOf(staker);
            coinAmount = tokenAmount.div(params.stakeRate()).mul(1e8);
        }

        //Calculation of fee rate
        uint256 feeRate = params.feeRate();
        uint256 fee = (tokenAmount.sub(feeTokenAmount)).mul(feeRate).div(1000);
        uint256 _pmFee = fee.div(3);
        sFee = sFee.add(fee);
        pmFee = pmFee.add(_pmFee);

        uint256 move = tokenAmount.sub(fee);

        if (tokenAmount >= tokens[staker]) {
            tokens[staker] = 0;
            cTokens[staker] = 0;
        } else {
            tokens[staker] = tokens[staker].sub(tokenAmount);
            cTokens[staker] = cTokens[staker].sub(tokenAmount);
        }

        feeToken.transferFrom(receiver, pmFeeHolder, feeTokenAmount);
        token.transfer(pmFeeHolder, _pmFee);
        token.transfer(blackhole, fee - _pmFee);

        coin.burn(staker, coinAmount);
        cToken.burn(staker, tokenAmount);
        token.transfer(receiver, move);

        coins[staker] = coins[staker].sub(coinAmount);
        totalCoin = totalCoin.sub(coinAmount);
        totalToken = totalToken.sub(tokenAmount);
        totalCToken = totalCToken.sub(tokenAmount);

        uint256 blockNumber = getBlockNumber();
        if (fundsFeeStates[staker].fundsFee <= fundsTokenAmount) {
            fundsFeeStates[staker].fundsFee = 0;
        } else {
            fundsFeeStates[staker].fundsFee =
                fundsFeeStates[staker].fundsFee -
                fundsTokenAmount;
        }

        fundsFeeStates[staker].block = blockNumber;
        emit RedeemEvent(tokenAmount, move, fee, coinAmount);
    }

    /**
     * @notice Abnormally redeem anyAmount internal
     * @param coinAmount The number of coin will be redeemed
     * @param receiver Address of receiving
     */
    function _abnormalRedeem(uint256 coinAmount, address receiver) internal {
        require(esm.isClosed(), "System not Closed yet.");
        address from = msg.sender;
        require(coinAmount > 0, "The quantity is less than zero");
        require(coin.balanceOf(from) > 0, "The coin no balance.");
        require(coinAmount <= coin.balanceOf(from), "Coin balance exceed");

        uint256 tokenAmount = coinAmount.mul(totalToken).div(totalCoin);

        if (tokens[from] >= tokenAmount) {
            tokens[from] = tokens[from].sub(tokenAmount);
        } else {
            tokens[from] = 0;
            cTokens[from] = 0;
        }

        if (coins[from] >= coinAmount) {
            coins[from] = coins[from].sub(coinAmount);
        } else {
            coins[from] = 0;
        }

        if (cToken.balanceOf(from) <= tokenAmount) {
            cTokens[from] = 0;
            cToken.burn(from, cToken.balanceOf(from));
            totalCToken = totalCToken.sub(cToken.balanceOf(from));
        } else {
            cTokens[from] = cTokens[from].sub(tokenAmount);
            cToken.burn(from, tokenAmount);
            totalCToken = totalCToken.sub(tokenAmount);
        }

        //Calculation of fee rate
        uint256 feeRate = params.feeRate();
        uint256 fee = tokenAmount.mul(feeRate).div(1000);
        uint256 _pmFee = fee.div(3);
        sFee = sFee.add(fee);
        pmFee = pmFee.add(_pmFee);

        //用户可提取的部分要减去手续费
        uint256 move = tokenAmount.sub(fee);
        token.transfer(pmFeeHolder, _pmFee);
        token.transfer(blackhole, fee - _pmFee);
        coin.burn(from, coinAmount);
        token.transfer(receiver, move);

        totalCoin = totalCoin.sub(coinAmount);
        totalToken = totalToken.sub(tokenAmount);

        emit RedeemEvent(tokenAmount, move, fee, coinAmount);
    }

    /**
     * @notice Normally redeem anyAmount
     * @param coinAmount The number of coin will be redeemed
     * @param receiver Address of receiving
     */
    function redeem(uint256 coinAmount, address receiver) public {
        _normalRedeem(coinAmount, receiver);
    }

    /**
     * @notice Normally redeem anyAmount to msg.sender
     * @param coinAmount The number of coin will be redeemed
     */
    function redeem(uint256 coinAmount) public {
        redeem(coinAmount, msg.sender);
    }


    /**
     * @notice System shutdown under the redemption rule
     * @param coinAmount The number coin
     * @param receiver Address of receiving
     */
    function oRedeem(uint256 coinAmount, address receiver) public {
        _abnormalRedeem(coinAmount, receiver);
    }

    /**
     * @notice System shutdown under the redemption rule
     * @param coinAmount The number coin
     */
    function oRedeem(uint256 coinAmount) public {
        oRedeem(coinAmount, msg.sender);
    }

    /**
     * @notice Refresh reward speed.
     */
    function setRewardSpeed(uint256 speed, address coinAddress)
        public
        onlyWhiter
    {
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];
        updateIndex();
        rewardCoins[rewardCoinSub].rewardSpeed = speed;
    }

    /**
     * @notice Init RewardCoin array
     */
    function InitRewardCoin() public onlyWhiter {
        //Fist reward coin information
        addRewardCoin(
            0xD78B0A147EE7879F14a7CEF25761CB58ED978681,
            0,
            2.5e8,
            1e16,
            0,
            1e16
        );
        //Second reward coin information
        addRewardCoin(
            0x836ae4569F4c740A295Fc7a8438C928b7097d446,
            0,
            5e18,
            1e36,
            0,
            1e24
        );
    }

    /**
     * @notice Get rewardCoins
     */
    function getRewardCoins() public view returns (RewardCoin[] memory) {
        return rewardCoins;
    }

    /**
     * @notice Add a new RewardCoin
     */
    function addRewardCoin(
        address coinAddress,
        uint256 rewardTotal,
        uint256 rewardSpeed,
        uint256 initialIndex,
        uint256 index,
        uint256 doubleScale
    ) public onlyWhiter {
        require(
            rewardCoins.length <= 20,
            "The currency slot has been used up, please modify other currency information as appropriate"
        );
        for (uint256 i = 0; i < rewardCoins.length; i++) {
            require(
                coinAddress != rewardCoins[i].coinAddress,
                "The current currency has been added, please add a new currency."
            );
        }
        uint256 blockNumber = getBlockNumber();
        rewardCoins.push(
            RewardCoin(
                coinAddress,
                rewardTotal,
                rewardSpeed,
                initialIndex,
                index,
                blockNumber,
                doubleScale,
                IERC20(coinAddress)
            )
        );
        rewardCoinIndex[coinAddress] = rewardCoins.length - 1;
    }

    /**
     * @notice Used to correct the effect of one's actions on one's own earnings
     *         System shutdown will no longer count
     */
    function updateIndex() public {
        if (esm.isClosed()) {
            return;
        }
        uint256 blockNumber = getBlockNumber();
        for (uint256 i = 0; i < rewardCoins.length; i++) {
            uint256 deltBlock = blockNumber.sub(rewardCoins[i].blockNumber);
            if (deltBlock > 0 && params.isLowestLimit(totalCoin)) {
                uint256 accruedReward =
                    rewardCoins[i].rewardSpeed.mul(deltBlock);
                uint256 ratio =
                    totalToken == 0
                        ? 0
                        : accruedReward.mul(rewardCoins[i].doubleScale).div(
                            totalToken
                        );
                rewardCoins[i].index = rewardCoins[i].index.add(ratio);
                rewardCoins[i].blockNumber = blockNumber;
            } else {
                rewardCoins[i].index = rewardCoins[i].index;
                rewardCoins[i].blockNumber = blockNumber;
            }
            emit IndexUpdate(deltBlock, blockNumber, rewardCoins[i].index);
        }
    }

    /**
     * @notice Used to correct the effect of one's actions on one's own earnings
     *         System shutdown will no longer count
     * @param account staker address
     */
    function accuredToken(address account) internal returns (uint256) {
        updateIndex();

        if (!isOrNot[account]) {
            // init
            for (uint256 i = 0; i < 20; i++) {
                stakerStateArray[account].push(StakerState(0, 0));
            }
            isOrNot[account] = true;
        }

        // update
        for (uint256 i = 0; i < rewardCoins.length; i++) {
            stakerStateArray[account][i].reward = _getReward(
                account,
                rewardCoins[i].coinAddress
            );
            stakerStateArray[account][i].index = rewardCoins[i].index;
        }
    }

    /**
     * @notice select holder's StateArray
     */
    function getStakerStateArray() public view returns (StakerState[] memory) {
        return stakerStateArray[msg.sender];
    }

    /**
     * @notice Calculate the current holder's mining income
     * @param staker Address of holder
     */
    function _getReward(address staker, address coinAddress)
        internal
        view
        returns (uint256 value)
    {
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];

        //The reward will not be calculated if the number of Coins in the current system is insufficient
        value = stakerStateArray[staker][rewardCoinSub].reward.add(
            rewardCoins[rewardCoinSub]
                .index
                .sub(stakerStateArray[staker][rewardCoinSub].index)
                .mul(tokens[staker])
                .div(rewardCoins[rewardCoinSub].doubleScale)
        );
    }

    /**
     * @notice Estimate the mortgagor's reward
     * @param account Address of staker
     */
    function getHolderReward(address account, address coinAddress)
        public
        view
        returns (uint256 value)
    {
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];
        uint256 blockReward2 =
            (totalToken == 0 ||
                esm.isClosed() ||
                !params.isLowestLimit(totalCoin))
                ? 0
                : getBlockNumber()
                    .sub(rewardCoins[rewardCoinSub].blockNumber)
                    .mul(rewardCoins[rewardCoinSub].rewardSpeed)
                    .mul(tokens[account])
                    .div(totalToken);
        value = _getReward(account, coinAddress) + blockReward2;
    }

    /**
     * @notice Extract the current reward in one go
     * @param holder Address of receiver
     */
    function claimToken(address holder, address coinAddress) public {
        require(
            _judgePledgeRate(holder),
            "The current pledge rate does not meet the system pledge rate requirements"
        );
        accuredToken(holder);
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];
        uint256 value =
            stakerStateArray[holder][rewardCoinSub].reward.min(
                rewardCoins[rewardCoinSub].rewardTotal
            );
        require(value > 0, "The reward of address is zero.");

        rewardCoins[rewardCoinSub].coin.transfer(holder, value);
        rewardCoins[rewardCoinSub].rewardTotal = rewardCoins[rewardCoinSub]
            .rewardTotal
            .sub(value);

        stakerStateArray[holder][rewardCoinSub].index = rewardCoins[
            rewardCoinSub
        ]
            .index;
        stakerStateArray[holder][rewardCoinSub].reward = stakerStateArray[
            holder
        ][rewardCoinSub]
            .reward
            .sub(value);

        emit ClaimToken(holder, value, coinAddress);
    }

    /**
     * @notice Get block number now
     */
    function getBlockNumber() public view returns (uint256) {
        return block.number;
    }

    /**
     * @notice Inject token to reward
     * @param amount The number of injecting
     */
    function injectReward(uint256 amount, address coinAddress)
        external
        onlyOwner
    {
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];
        rewardCoins[rewardCoinSub].coin.transferFrom(
            msg.sender,
            address(this),
            amount
        );
        rewardCoins[rewardCoinSub].rewardTotal = rewardCoins[rewardCoinSub]
            .rewardTotal
            .add(amount);

        emit InjectReward(amount, coinAddress);
    }

    /**
     * @notice Extract token from reward
     * @param account Address of receiver
     * @param amount The number of extracting
     */
    function extractReward(
        address account,
        uint256 amount,
        address coinAddress
    ) external onlyOwner {
        uint256 rewardCoinSub = rewardCoinIndex[coinAddress];

        require(
            amount <= rewardCoins[rewardCoinSub].rewardTotal,
            "withdraw overflow."
        );
        rewardCoins[rewardCoinSub].coin.transfer(account, amount);
        rewardCoins[rewardCoinSub].rewardTotal = rewardCoins[rewardCoinSub]
            .rewardTotal
            .sub(amount);

        emit ExtractReward(account, amount, coinAddress);
    }
}
