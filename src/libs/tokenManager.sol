pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract TokenManager {
    using SafeERC20 for IERC20;

    AggregatorV3Interface public immutable ethUsdFeed;

    /// @notice Metadatos de tokens registrados
    struct TokenInfo {
        bool registered;
        uint8 decimals; // decimales del token (para ETH usar 18)
        address priceFeed; // feed de precios Chainlink token/USD (puede ser 0 para ETH si se establece ethUsdFeed)
    }
    mapping(address => TokenInfo) public tokenInfo;

    event tokenSupported(address token, address priceFeed);
    event tokenUnsupported(address token);
    event tokenUpdated(address token, uint8 decimals, address newPriceFeed);

    error InvalidParams();

    constructor(address _ethUsdFeed) {
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
    }

    /// @notice función para registrar un nuevos tokens de criptos en el banco
    function supportToken(address token, uint8 decimals, address priceFeed) internal {
        if (token == address(0) || decimals == 0) {
            revert InvalidParams();
        }
        tokenInfo[token] = TokenInfo({
            registered: true,
            decimals: decimals,
            priceFeed: priceFeed
        });
        emit tokenSupported(token, priceFeed);
    }

    /// @notice función para desregistrar un token de cripto en el banco
    function unsupportToken(address token) internal {
        tokenInfo[token].registered = false;
        emit tokenUnsupported(token);
    }

    function updateToken(address token, uint8 decimals, address newPriceFeed) internal {
        if (!tokenInfo[token].registered || token == address(0) || decimals == 0) {
            revert InvalidParams();
        }
        tokenInfo[token].decimals = decimals;
        tokenInfo[token].priceFeed = newPriceFeed;
        emit tokenUpdated(token, decimals, newPriceFeed);
    }

    function getSupportedTokenInfo(address token) external view returns (TokenInfo memory) {
        return tokenInfo[token];
    }

    function isTokenSupported(address token) external view returns (bool) {
        return tokenInfo[token].registered;
    }

    function convertTokenAmountToUsd(address token, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;

        // obtenemos el feed de precios correspondiente
        // esto quiere decir: al intanciar nuestro contrato nostros le pasamos el feed de ETH/USD
        // significa que creamos un contrato, en el cual puede determinar el valor de ETH en USD en tiempo real
        AggregatorV3Interface feed = ethUsdFeed;
        // obtenemos los decimales del feed
        uint8 feedDecimals = feed.decimals();

        // decimales del token default 18 (ETH)
        uint8 tokenDecimalsLocal = 18;
        //Si el token que queremos convertir es ETH nativo usamos el feed ethUsdFeed
        if (token == ETH_ADDRESS) {
            //Usamos el feed ethUsdFeed ya seteado en el constructor
            // obtenemos el precio del ETH en USD
            (, int256 priceInt, , , ) = feed.latestRoundData();
            require(priceInt > 0, "invalid price");
            uint256 price = uint256(priceInt);
            //Calculamos el valor en USD
            // usdWithPriceDecimals = (amount * price) / (10 ** tokenDecimals)
            uint256 usdWithPriceDecimals = (amount * price) / (10 ** tokenDecimalsLocal);
            // ajustamos a USDC_DECIMALS
            // si los decimales del feed son mayores o iguales a USDC_DECIMALS, dividimos
            // si no, multiplicamos
            if (feedDecimals >= USDC_DECIMALS) {
                return usdWithPriceDecimals / (10 ** (feedDecimals - USDC_DECIMALS));
            } else {
                return usdWithPriceDecimals * (10 ** (USDC_DECIMALS - feedDecimals));
            }
        } else {
            // Si el token no es ETH nativo y es un ERC20, obtenemos su feed de precios y decimales
            // Validamos que este registrado y tenga feed de precios
            TokenInfo memory t = tokenInfo[token];
            require(t.registered, "token not registered");
            require(t.priceFeed != address(0), "no feed");
            //Obtenemos el feed y sus decimales
            feed = AggregatorV3Interface(t.priceFeed);
            feedDecimals = feed.decimals();
            tokenDecimalsLocal = t.decimals;
            // obtenemos el precio del token en USD
            (, int256 priceInt, , , ) = feed.latestRoundData();
            require(priceInt > 0, "invalid price");
            uint256 price = uint256(priceInt);

            //Calculamos el valor en USD
            // usdWithPriceDecimals = (amount * price) / (10 ** tokenDecimals)
            uint256 usdWithPriceDecimals = (amount * price) / (10 ** tokenDecimalsLocal);
            // ajustamos a USDC_DECIMALS
            // si los decimales del feed son mayores o iguales a USDC_DECIMALS, dividimos
            // si no, multiplicamos
            if (feedDecimals >= USDC_DECIMALS) {
                return usdWithPriceDecimals / (10 ** (feedDecimals - USDC_DECIMALS));
            } else {
                return usdWithPriceDecimals * (10 ** (USDC_DECIMALS - feedDecimals));
            }
        }
    }
}