pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "./OpenOraclePriceData.sol";
import "./ChannelsOracleConfig.sol";

contract ChannelsAnchoredOracle is ChannelsOracleConfig {

    /// @notice The Open Oracle Price Data contract
    OpenOraclePriceData public immutable priceData;

    /// @notice The Open Oracle Reporter
    address public immutable reporter;

    /// @notice The highest ratio of the new price to the anchor price that will still trigger the price to be updated
    uint public immutable upperBoundAnchorRatio;

    /// @notice The lowest ratio of the new price to the anchor price that will still trigger the price to be updated
    uint public immutable lowerBoundAnchorRatio;

    /// @notice Official prices by symbol hash, default mul 1e6
    mapping(bytes32 => uint) public prices;

    /// @notice Oracle Args
    string _price;
    /// @notice Oracle Args
    ERC20 _token;
    /// @notice Oracle Args
    QuotedPrice _priceContract;
    /// @notice Oracle Args
    address _priceAddress;

    /// @notice The event emitted when new prices are posted but the stored price is not updated due to the anchor
    event PriceGuarded(string symbol, uint reporter, uint anchor);

    /// @notice The event emitted when the stored price is updated
    event PriceUpdated(string symbol, uint price);
    /**
     * @notice Construct a uniswap anchored view for a set of token configurations
     * @dev Note that to avoid immature TWAPs, the system must run for at least a single anchorPeriod before using.
     * @param reporter_ The reporter whose prices are to be used
     * @param anchorToleranceMantissa_ The percentage tolerance that the reporter may deviate from the uniswap anchor
     * @param configs The static token configurations which define what prices are supported and how
     */
    constructor(
        address tokenAddress,
        address priceAddress,
        OpenOraclePriceData priceData_,
        address reporter_,
        uint anchorToleranceMantissa_,
        TokenConfig[] memory configs
    ) ChannelsOracleConfig(configs) public {

        _token = ERC20(tokenAddress);
        _priceContract = QuotedPrice(priceAddress);
        _priceAddress = priceAddress;

        priceData = priceData_;
        reporter = reporter_;

        // Allow the tolerance to be whatever the deployer chooses, but prevent under/overflow (and prices from being 0)
        upperBoundAnchorRatio = anchorToleranceMantissa_ > uint(- 1) - 100e16 ? uint(- 1) : 100e16 + anchorToleranceMantissa_;
        lowerBoundAnchorRatio = anchorToleranceMantissa_ < 100e16 ? 100e16 - anchorToleranceMantissa_ : 1;

        for (uint i = 0; i < configs.length; i++) {
            TokenConfig memory config = configs[i];
            require(config.baseUnit > 0, "baseUnit must be greater than zero");
        }
    }

    /// @notice symbol, example HT/USDT
    function queryPriceBySymbol(string memory symbol) public {
        if (_token.allowance(address(this), _priceAddress) < 200000000) {
            _token.approve(_priceAddress, 0);
            _token.approve(_priceAddress, 1000000000000000000);
        }
        _price = _priceContract.queryPrice(symbol);
    }

    function getPrice() public view returns (string memory){
        return _price;
    }

    /**
     * @notice Get the official price for a symbol
     * @param symbol The symbol to fetch the price of
     * @return Price denominated in USD, with 6 decimals
     */
    function price(string memory symbol) external view returns (uint) {
        TokenConfig memory config = getTokenConfigBySymbol(symbol);
        return priceInternal(config);
    }

    function priceInternal(TokenConfig memory config) internal view returns (uint) {
        if (config.priceSource == PriceSource.REPORTER) return prices[config.symbolHash];
        if (config.priceSource == PriceSource.FIXED_USD) return config.fixedPrice;
    }

    /**
     * @notice Get the underlying price of a cToken
     * @dev Implements the PriceOracle interface for Channels v2.
     * @param cToken The cToken address for price retrieval
     * @return Price denominated in USD, with 18 decimals, for the given cToken address
     */
    function getUnderlyingPrice(address cToken) external view returns (uint) {
        TokenConfig memory config = getTokenConfigByCToken(cToken);
        // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
        // Since the prices in this view have 6 decimals, we must scale them by 1e(36 - 6 - baseUnit)
        return mul(1e30, priceInternal(config)) / config.baseUnit;
    }

    /**
     * @notice Post open oracle reporter prices, and recalculate stored price by comparing to anchor
     * @dev We let anyone pay to post anything, but only prices from configured reporter will be stored in the view.
     * @param messages The messages to post to the oracle
     * @param signatures The signatures for the corresponding messages
     * @param symbols The symbols to compare to anchor for authoritative reading
     */
    function postPrices(bytes[] calldata messages, bytes[] calldata signatures, string[] calldata symbols) external {
        require(messages.length == signatures.length, "messages and signatures must be 1:1");
        require(msg.sender == reporter, "msg sender must be reporter ");

        // Save the prices
        for (uint i = 0; i < messages.length; i++) {
            priceData.put(messages[i], signatures[i]);
        }

        // Try to update the view storage
        for (uint i = 0; i < symbols.length; i++) {
            postPriceInternal(symbols[i]);
        }
    }

    function postPriceInternal(string memory symbol) internal {
        TokenConfig memory config = getTokenConfigBySymbol(symbol);
        require(config.priceSource == PriceSource.REPORTER, "only reporter prices get posted");
        bytes32 symbolHash = keccak256(abi.encodePacked(symbol));
        uint reporterPrice = priceData.getPrice(reporter, symbol);

        queryPriceBySymbol(config.symbolName);

        uint anchorPrice;
        anchorPrice = parseInt(_price, 6);

        if (isWithinAnchor(reporterPrice, anchorPrice)) {
            prices[symbolHash] = reporterPrice;
            emit PriceUpdated(symbol, reporterPrice);
        } else {
            emit PriceGuarded(symbol, reporterPrice, anchorPrice);
            revert("reporterPrice is not with in Anchor");
        }
    }

    function isWithinAnchor(uint reporterPrice, uint anchorPrice) internal view returns (bool) {
        if (reporterPrice > 0) {
            uint anchorRatio = mul(anchorPrice, 100e16) / reporterPrice;
            return anchorRatio <= upperBoundAnchorRatio && anchorRatio >= lowerBoundAnchorRatio;
        }
        return false;
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }

    function parseInt(string memory _a, uint _b) private pure returns (uint _parsedInt) {
        bytes memory bresult = bytes(_a);
        uint mint = 0;
        bool decimals = false;
        for (uint i = 0; i < bresult.length; i++) {
            if ((uint(uint8(bresult[i])) >= 48) && (uint(uint8(bresult[i])) <= 57)) {
                if (decimals) {
                    if (_b == 0) {
                        break;
                    } else {
                        _b--;
                    }
                }
                mint *= 10;
                mint += uint(uint8(bresult[i])) - 48;
            } else if (uint(uint8(bresult[i])) == 46) {
                decimals = true;
            }
        }
        if (_b > 0) {
            mint *= 10 ** _b;
        }
        return mint;
    }
}

interface QuotedPrice {
    function queryPrice(string calldata symbol) external returns (string memory price);
}

interface ERC20 {
    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address _owner, address _spender) external returns (uint256 remaining);
}

