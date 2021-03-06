pragma solidity ^0.6.0;

// import files from common directory
import { TokenInterface , MemoryInterface, EventInterface} from "../common/interfaces.sol";
import { Stores } from "../common/stores.sol";
import { DSMath } from "../common/math.sol";

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface OneInchInterace {
    function swap(
        TokenInterface fromToken,
        TokenInterface toToken,
        uint256 fromTokenAmount,
        uint256 minReturnAmount,
        uint256 guaranteedAmount,
        address payable referrer,
        address[] calldata callAddresses,
        bytes calldata callDataConcat,
        uint256[] calldata starts,
        uint256[] calldata gasLimitsAndValues
    )
    external
    payable
    returns (uint256 returnAmount);
}

interface OneProtoInterface {
    function swapWithReferral(
        TokenInterface fromToken,
        TokenInterface destToken,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata distribution,
        uint256 flags, // See contants in IOneSplit.sol
        address referral,
        uint256 feePercent
    ) external payable returns(uint256);

    function swapWithReferralMulti(
        TokenInterface[] calldata tokens,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata distribution,
        uint256[] calldata flags,
        address referral,
        uint256 feePercent
    ) external payable returns(uint256 returnAmount);

    function getExpectedReturn(
        TokenInterface fromToken,
        TokenInterface destToken,
        uint256 amount,
        uint256 parts,
        uint256 flags // See constants in IOneSplit.sol
    )
    external
    view
    returns(
        uint256 returnAmount,
        uint256[] memory distribution
    );
}


contract OneHelpers is Stores, DSMath {
    using SafeERC20 for IERC20;
    /**
     * @dev Return  1Inch Address
     */
    function getOneInchAddress() internal pure returns (address) {
        return 0x11111254369792b2Ca5d084aB5eEA397cA8fa48B;
    }

    /**
     * @dev Return 1proto Address
     */
    function getOneProtoAddress() internal pure returns (address payable) {
        return 0x50FDA034C0Ce7a8f7EFDAebDA7Aa7cA21CC1267e;
    }

    /**
     * @dev Return 1inch Token Taker Address
     */
    function getOneInchTokenTaker() internal pure returns (address payable) {
        return 0xE4C9194962532fEB467DCe8b3d42419641c6eD2E;
    }

    /**
     * @dev Return 1inch swap function sig
     */
    function getOneInchSig() internal pure returns (bytes4) {
        return 0xf88309d7;
    }

    function getReferralAddr() internal pure returns (address) {
        return 0xa7615CD307F323172331865181DC8b80a2834324;  // TODO - change address
    }

    function convert18ToDec(uint _dec, uint256 _amt) internal pure returns (uint256 amt) {
        amt = (_amt / 10 ** (18 - _dec));
    }

    function convertTo18(uint _dec, uint256 _amt) internal pure returns (uint256 amt) {
        amt = mul(_amt, 10 ** (18 - _dec));
    }

    function getTokenBal(TokenInterface token) internal view returns(uint _amt) {
        _amt = address(token) == getEthAddr() ? address(this).balance : token.balanceOf(address(this));
    }

    function getTokensDec(TokenInterface buyAddr, TokenInterface sellAddr) internal view returns(uint buyDec, uint sellDec) {
        buyDec = address(buyAddr) == getEthAddr() ?  18 : buyAddr.decimals();
        sellDec = address(sellAddr) == getEthAddr() ?  18 : sellAddr.decimals();
    }

    function getSlippageAmt(
        TokenInterface _buyAddr,
        TokenInterface _sellAddr,
        uint _sellAmt,
        uint unitAmt
    ) internal view returns(uint _slippageAmt) {
        (uint _buyDec, uint _sellDec) = getTokensDec(_buyAddr, _sellAddr);
        uint _sellAmt18 = convertTo18(_sellDec, _sellAmt);
        _slippageAmt = convert18ToDec(_buyDec, wmul(unitAmt, _sellAmt18));
    }

    function convertToTokenInterface(address[] memory tokens) internal pure returns(TokenInterface[] memory) {
        TokenInterface[] memory _tokens = new TokenInterface[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            _tokens[i] = TokenInterface(tokens[i]);
        }
        return _tokens;
    }

    function _transfer(address payable to, IERC20 token, uint _amt) internal {
        address(token) == getEthAddr() ?
            to.transfer(_amt) :
            token.safeTransfer(to, _amt);
    }

    function takeFee(
        address token,
        uint amount,
        address feeCollector,
        uint feePercent
    ) internal returns (uint leftAmt, uint feeAmount){
        if (feeCollector != address(0)) {
            feeAmount = wmul(amount, feePercent);
            leftAmt = sub(amount, feeAmount);
            uint feeCollectorAmt = wmul(feeAmount, 3 * 10 ** 17);
            uint restAmt = sub(feeAmount, feeCollectorAmt);
            _transfer(payable(feeCollector), IERC20(token), feeCollectorAmt);
            _transfer(payable(getReferralAddr()), IERC20(token), restAmt);
        } else {
            leftAmt = amount;
        }
    }
}


contract Resolver is OneHelpers {
    function checkOneInchSig(bytes memory callData) internal pure returns(bool isOk) {
        bytes memory _data = callData;
        bytes4 sig;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            sig := mload(add(_data, 32))
        }
        isOk = sig == getOneInchSig();
    }

    struct OneProtoData {
        TokenInterface sellToken;
        TokenInterface buyToken;
        uint _sellAmt;
        uint _buyAmt;
        uint unitAmt;
        address feeCollector;
        uint256 feeAmount;
        uint[] distribution;
        uint disableDexes;
    }
    function oneProtoSwap(OneProtoInterface oneSplitContract, OneProtoData memory oneProtoData) internal returns (uint buyAmt){
        TokenInterface _sellAddr = oneProtoData.sellToken;
        TokenInterface _buyAddr = oneProtoData.buyToken;
        uint _sellAmt = oneProtoData._sellAmt;

        uint _slippageAmt = getSlippageAmt(_buyAddr, _sellAddr, _sellAmt, oneProtoData.unitAmt);

        uint ethAmt;
        if (address(_sellAddr) == getEthAddr()) {
            ethAmt = _sellAmt;
        } else {
            _sellAddr.approve(address(oneSplitContract), _sellAmt);
        }

        uint initalBal = getTokenBal(_buyAddr);

        oneSplitContract.swapWithReferral.value(ethAmt)(
            _sellAddr,
            _buyAddr,
            _sellAmt,
            _slippageAmt,
            oneProtoData.distribution,
            oneProtoData.disableDexes,
            getReferralAddr(),
            0
        );

        uint finalBal = getTokenBal(_buyAddr);
        buyAmt = sub(finalBal, initalBal);

        require(_slippageAmt <= buyAmt, "Too much slippage");
    }

    struct OneProtoMultiData {
        address[] tokens;
        TokenInterface sellToken;
        TokenInterface buyToken;
        uint _sellAmt;
        uint _buyAmt;
        uint unitAmt;
        address feeCollector;
        uint256 feeAmount;
        uint[] distribution;
        uint[] disableDexes;
    }
    function oneProtoSwapMulti(OneProtoMultiData memory oneProtoData) internal returns (uint buyAmt){
        OneProtoInterface oneSplitContract = OneProtoInterface(getOneProtoAddress());
        TokenInterface _sellAddr = oneProtoData.sellToken;
        TokenInterface _buyAddr = oneProtoData.buyToken;
        uint _sellAmt = oneProtoData._sellAmt;
        uint _slippageAmt = getSlippageAmt(_buyAddr, _sellAddr, _sellAmt, oneProtoData.unitAmt);

        uint ethAmt;
        if (address(_sellAddr) == getEthAddr()) {
            ethAmt = _sellAmt;
        } else {
            _sellAddr.approve(address(oneSplitContract), _sellAmt);
        }

        uint initalBal = getTokenBal(_buyAddr);
        oneSplitContract.swapWithReferralMulti.value(ethAmt)(
            convertToTokenInterface(oneProtoData.tokens),
            _sellAmt,
            _slippageAmt,
            oneProtoData.distribution,
            oneProtoData.disableDexes,
            getReferralAddr(),
            0
        );
        uint finalBal = getTokenBal(_buyAddr);

        buyAmt = sub(finalBal, initalBal);

        require(_slippageAmt <= buyAmt, "Too much slippage");
    }

    function oneInchSwap(
        TokenInterface _buyAddr,
        TokenInterface _sellAddr,
        bytes memory callData,
        uint sellAmt,
        uint unitAmt,
        uint ethAmt
    ) internal returns (uint buyAmt) {
        (uint _buyDec, uint _sellDec) = getTokensDec(_buyAddr, _sellAddr);
        uint _sellAmt18 = convertTo18(_sellDec, sellAmt);
        uint _slippageAmt = convert18ToDec(_buyDec, wmul(unitAmt, _sellAmt18));
        uint initalBal = getTokenBal(_buyAddr);

        // solium-disable-next-line security/no-call-value
        (bool success, ) = address(getOneInchAddress()).call.value(ethAmt)(callData);
        if (!success) revert("1Inch-swap-failed");

        uint finalBal = getTokenBal(_buyAddr);
        buyAmt = sub(finalBal, initalBal);

        require(_slippageAmt <= buyAmt, "Too much slippage");
    }

}

contract OneProtoEventResolver is Resolver {
    event LogSell(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        uint256 getId,
        uint256 setId
    );

    event LogSellFee(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        address indexed collector,
        uint256 fee,
        uint256 getId,
        uint256 setId
    );

    function emitLogSell(
        OneProtoData memory oneProtoData,
        uint256 getId,
        uint256 setId
    ) internal {
        bytes32 _eventCode;
        bytes memory _eventParam;
        if (oneProtoData.feeCollector == address(0)) {
            emit LogSell(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
            _eventCode = keccak256("LogSell(address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
        } else {
            emit LogSellFee(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
            _eventCode = keccak256("LogSellFee(address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
        }
        emitEvent(_eventCode, _eventParam);
    }

    event LogSellTwo(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        uint256 getId,
        uint256 setId
    );

     event LogSellFeeTwo(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        address indexed collector,
        uint256 fee,
        uint256 getId,
        uint256 setId
    );

    function emitLogSellTwo(
        OneProtoData memory oneProtoData,
        uint256 getId,
        uint256 setId
    ) internal {
        bytes32 _eventCode;
        bytes memory _eventParam;
        if (oneProtoData.feeCollector == address(0)) {
            emit LogSellTwo(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
            _eventCode = keccak256("LogSellTwo(address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
        } else {
            emit LogSellFeeTwo(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
            _eventCode = keccak256("LogSellFeeTwo(address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
        }
        emitEvent(_eventCode, _eventParam);
    }

    event LogSellMulti(
        address[] tokens,
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        uint256 getId,
        uint256 setId
    );

     event LogSellFeeMulti(
        address[] tokens,
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        address indexed collector,
        uint256 fee,
        uint256 getId,
        uint256 setId
    );

    function emitLogSellMulti(
        OneProtoMultiData memory oneProtoData,
        uint256 getId,
        uint256 setId
    ) internal {
        bytes32 _eventCode;
        bytes memory _eventParam;
        if (oneProtoData.feeCollector == address(0)) {
            emit LogSellMulti(
                oneProtoData.tokens,
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
            _eventCode = keccak256("LogSellMulti(address[],address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                oneProtoData.tokens,
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                getId,
                setId
            );
        } else {
            emit LogSellFeeMulti(
                oneProtoData.tokens,
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
            _eventCode = keccak256("LogSellFeeMulti(address[],address,address,uint256,uint256,uint256,uint256)");
            _eventParam = abi.encode(
                oneProtoData.tokens,
                address(oneProtoData.buyToken),
                address(oneProtoData.sellToken),
                oneProtoData._buyAmt,
                oneProtoData._sellAmt,
                oneProtoData.feeCollector,
                oneProtoData.feeAmount,
                getId,
                setId
            );
        }
        emitEvent(_eventCode, _eventParam);
    }

}
contract OneProtoResolverHelpers is OneProtoEventResolver {
    function _sell(
        OneProtoData memory oneProtoData,
        uint256 feePercent,
        uint256 getId,
        uint256 setId
    ) internal {
        uint _sellAmt = getUint(getId, oneProtoData._sellAmt);
        
        oneProtoData._sellAmt = _sellAmt == uint(-1) ?
            getTokenBal(oneProtoData.sellToken) :
            _sellAmt;

        OneProtoInterface oneSplitContract = OneProtoInterface(getOneProtoAddress());

        (, oneProtoData.distribution) = oneSplitContract.getExpectedReturn(
                oneProtoData.sellToken,
                oneProtoData.buyToken,
                oneProtoData._sellAmt,
                5,
                0
            );

        oneProtoData._buyAmt = oneProtoSwap(
            oneSplitContract,
            oneProtoData
        );

        (uint feeAmount, uint leftBuyAmt) = takeFee(
            address(oneProtoData.buyToken),
            oneProtoData._buyAmt,
            oneProtoData.feeCollector,
            feePercent
        );
        setUint(setId, leftBuyAmt);
        oneProtoData.feeAmount = feeAmount;

        emitLogSell(oneProtoData, getId, setId);
    }

    function _sellTwo(
        OneProtoData memory oneProtoData,
        uint256 feePercent,
        uint getId,
        uint setId
    ) internal {
        uint _sellAmt = getUint(getId, oneProtoData._sellAmt);

        oneProtoData._sellAmt = _sellAmt == uint(-1) ?
            getTokenBal(oneProtoData.sellToken) :
            _sellAmt;

        oneProtoData._buyAmt = oneProtoSwap(
            OneProtoInterface(getOneProtoAddress()),
            oneProtoData
        );

        (uint feeAmount, uint leftBuyAmt) = takeFee(
            address(oneProtoData.buyToken),
            oneProtoData._buyAmt,
            oneProtoData.feeCollector,
            feePercent
        );
        setUint(setId, leftBuyAmt);
        oneProtoData.feeAmount = feeAmount;

        emitLogSellTwo(oneProtoData, getId, setId);
    }

    function _sellMulti(
        OneProtoMultiData memory oneProtoData,
        uint256 feePercent,
        uint getId,
        uint setId
    ) internal {
        uint _sellAmt = getUint(getId, oneProtoData._sellAmt);
        
        oneProtoData._sellAmt = _sellAmt == uint(-1) ?
            getTokenBal(oneProtoData.sellToken) :
            _sellAmt;

        oneProtoData._buyAmt = oneProtoSwapMulti(oneProtoData);
        uint leftBuyAmt;
        (oneProtoData.feeAmount, leftBuyAmt) = takeFee(
            address(oneProtoData.buyToken),
            oneProtoData._buyAmt,
            oneProtoData.feeCollector,
            feePercent
        );
        setUint(setId, leftBuyAmt);

        emitLogSellMulti(oneProtoData, getId, setId);
    }
}

contract OneProtoResolver is OneProtoResolverHelpers {
    /**
     * @dev Sell ETH/ERC20_Token using 1proto.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sell(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        uint getId,
        uint setId
    ) external payable {
        OneProtoData memory oneProtoData = OneProtoData({
            buyToken: TokenInterface(buyAddr),
            sellToken: TokenInterface(sellAddr),
            unitAmt: unitAmt,
            distribution: new uint[](0),
            feeCollector: address(0),
            _sellAmt: sellAmt,
            _buyAmt: 0,
            disableDexes: 0,
            feeAmount: 0
        });

        _sell(oneProtoData, 0, getId, setId);

    }

    /**
     * @dev Sell ETH/ERC20_Token using 1proto.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param feeCollector Fee amount to transfer.
     * @param feePercent Fee percentage on buyAmt.
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellFee(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        address feeCollector,
        uint feePercent,
        uint getId,
        uint setId
    ) external payable {
        require(feePercent > 0 && feePercent <= 2*10*16, "Fee more than 2%");
        require(feeCollector != address(0), "feeCollector is not vaild address");

        OneProtoData memory oneProtoData = OneProtoData({
            buyToken: TokenInterface(buyAddr),
            sellToken: TokenInterface(sellAddr),
            unitAmt: unitAmt,
            distribution: new uint[](0),
            feeCollector: feeCollector,
            _sellAmt: sellAmt,
            _buyAmt: 0,
            disableDexes: 0,
            feeAmount: 0
        });

        _sell(oneProtoData, feePercent, getId, setId);
    }

    /**
     * @dev Sell ETH/ERC20_Token using 1proto.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param distribution distribution of swap across different dex.
     * @param disableDexes disable a dex. (To disable none: 0)
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellTwo(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        uint[] calldata distribution,
        uint disableDexes,
        uint getId,
        uint setId
    ) external payable {
        OneProtoData memory oneProtoData = OneProtoData({
            buyToken: TokenInterface(buyAddr),
            sellToken: TokenInterface(sellAddr),
            unitAmt: unitAmt,
            distribution: distribution,
            disableDexes: disableDexes,
            _sellAmt: sellAmt,
            feeCollector: address(0),
            _buyAmt: 0,
            feeAmount: 0
        });

        _sellTwo(oneProtoData, 0, getId, setId);
    }


    /**
     * @dev Sell ETH/ERC20_Token using 1proto.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param distribution distribution of swap across different dex.
     * @param disableDexes disable a dex. (To disable none: 0)
     * @param feeCollector Fee amount to transfer.
     * @param feePercent Fee percentage on buyAmt.
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellFeeTwo(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        uint[] calldata distribution,
        uint disableDexes,
        address feeCollector,
        uint feePercent,
        uint getId,
        uint setId
    ) external payable {
        require(feePercent > 0 && feePercent <= 2*10*16, "Fee more than 2%");
        require(feeCollector != address(0), "feeCollector is not vaild address");
        OneProtoData memory oneProtoData = OneProtoData({
            buyToken: TokenInterface(buyAddr),
            sellToken: TokenInterface(sellAddr),
            unitAmt: unitAmt,
            distribution: distribution,
            disableDexes: disableDexes,
            feeCollector: feeCollector,
            _sellAmt: sellAmt,
            _buyAmt: 0,
            feeAmount: 0
        });

        _sellTwo(oneProtoData, feePercent, getId, setId);
    }

    /**
     * @dev Sell ETH/ERC20_Token using 1proto using muliple token.
     * @param tokens buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param distribution distribution of swap across different dex.
     * @param disableDexes disable a dex. (To disable none: 0)
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellMulti(
        address[] calldata tokens,
        uint sellAmt,
        uint unitAmt,
        uint[] calldata distribution,
        uint[] calldata disableDexes,
        uint getId,
        uint setId
    ) external payable {
        OneProtoMultiData memory oneProtoData = OneProtoMultiData({
            tokens: tokens,
            buyToken: TokenInterface(address(tokens[tokens.length - 1])),
            sellToken: TokenInterface(address(tokens[0])),
            unitAmt: unitAmt,
            distribution: distribution,
            disableDexes: disableDexes,
            _sellAmt: sellAmt,
            feeCollector: address(0),
            _buyAmt: 0,
            feeAmount: 0
        });

        _sellMulti(oneProtoData, 0, getId, setId);
    }

    /**
     * @dev Sell ETH/ERC20_Token using 1proto using muliple token.
     * @param tokens buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param distribution distribution of swap across different dex.
     * @param disableDexes disable a dex. (To disable none: 0)
     * @param feeCollector Fee amount to transfer.
     * @param feePercent Fee percentage on buyAmt.
     * @param getId Get token amount at this ID from `InstaMemory` Contract.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellFeeMulti(
        address[] calldata tokens,
        uint sellAmt,
        uint unitAmt,
        uint[] calldata distribution,
        uint[] calldata disableDexes,
        address feeCollector,
        uint feePercent,
        uint getId,
        uint setId
    ) external payable {
        require(feePercent > 0 && feePercent <= 2*10*16, "Fee more than 2%");
        require(feeCollector != address(0), "feeCollector is not vaild address");
        TokenInterface buyToken = TokenInterface(address(tokens[tokens.length-1]));
        OneProtoMultiData memory oneProtoData = OneProtoMultiData({
            tokens: tokens,
            buyToken: buyToken,
            sellToken: TokenInterface(address(tokens[0])),
            unitAmt: unitAmt,
            distribution: distribution,
            feeCollector: feeCollector,
            disableDexes: disableDexes,
            _sellAmt: sellAmt,
            _buyAmt: 0,
            feeAmount: 0
        });

        _sellMulti(oneProtoData, feePercent, getId, setId);
    }
}
contract OneInchResolver is OneProtoResolver {
    event LogSellThree(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        uint256 getId,
        uint256 setId
    );

     /**
     * @dev Sell ETH/ERC20_Token using 1split.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param callData Data from 1inch API.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellThree(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        bytes calldata callData,
        uint setId
    ) external payable {
        TokenInterface _buyAddr = TokenInterface(buyAddr);
        TokenInterface _sellAddr = TokenInterface(sellAddr);

        uint ethAmt;
        if (address(_sellAddr) == getEthAddr()) {
            ethAmt = sellAmt;
        } else {
            TokenInterface(_sellAddr).approve(getOneInchTokenTaker(), sellAmt);
        }

        require(checkOneInchSig(callData), "Not-swap-function");

        uint buyAmt = oneInchSwap(_buyAddr, _sellAddr, callData, sellAmt, unitAmt, ethAmt);

        setUint(setId, buyAmt);

        emit LogSellThree(address(_buyAddr), address(_sellAddr), buyAmt, sellAmt, 0, setId);
        bytes32 _eventCode = keccak256("LogSellThree(address,address,uint256,uint256,uint256,uint256)");
        bytes memory _eventParam = abi.encode(address(_buyAddr), address(_sellAddr), buyAmt, sellAmt, 0, setId);
        emitEvent(_eventCode, _eventParam);
    }

    event LogSellFeeThree(
        address indexed buyToken,
        address indexed sellToken,
        uint256 buyAmt,
        uint256 sellAmt,
        address indexed collector,
        uint256 fee,
        uint256 getId,
        uint256 setId
    );

     /**
     * @dev Sell ETH/ERC20_Token using 1split.
     * @param buyAddr buying token address.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAddr selling token amount.(For ETH: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
     * @param sellAmt selling token amount.
     * @param unitAmt unit amount of buyAmt/sellAmt with slippage.
     * @param callData Data from 1inch API.
     * @param setId Set token amount at this ID in `InstaMemory` Contract.
    */
    function sellFeeThree(
        address buyAddr,
        address sellAddr,
        uint sellAmt,
        uint unitAmt,
        bytes calldata callData,
        address feeCollector,
        uint feePercent,
        uint setId
    ) external payable {
        require(feePercent > 0 && feePercent <= 2*10*16, "Fee more than 2%");
        require(feeCollector != address(0), "feeCollector is not vaild address");

        TokenInterface _buyAddr = TokenInterface(buyAddr);
        TokenInterface _sellAddr = TokenInterface(sellAddr);

        uint ethAmt;
        if (address(_sellAddr) == getEthAddr()) {
            ethAmt = sellAmt;
        } else {
            TokenInterface(_sellAddr).approve(getOneInchTokenTaker(), sellAmt);
        }

        require(checkOneInchSig(callData), "Not-swap-function");

        uint buyAmt = oneInchSwap(_buyAddr, _sellAddr, callData, sellAmt, unitAmt, ethAmt);

        (uint feeAmount, uint leftBuyAmt) = takeFee(
            address(_buyAddr),
            buyAmt,
            feeCollector,
            feePercent
        );
        setUint(setId, leftBuyAmt);

        emit LogSellFeeThree(
            address(_buyAddr),
            address(_sellAddr),
            buyAmt,
            sellAmt,
            feeCollector,
            feeAmount,
            0,
            setId
        );
        bytes32 _eventCode = keccak256("LogSellThree(address,address,uint256,uint256,uint256,uint256)");
        bytes memory _eventParam = abi.encode(
            address(_buyAddr),
            address(_sellAddr),
            buyAmt,
            sellAmt,
            feeCollector,
            feeAmount,
            0,
            setId
        );
        emitEvent(_eventCode, _eventParam);
    }
}
contract ConnectOne is OneInchResolver {
    string public name = "1Inch-1proto-v1";
}