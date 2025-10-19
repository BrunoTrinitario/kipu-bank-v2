// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  KipuBank v2
  - Multi-token (ETH + ERC20)
  - Internal accounting in USD (6 decimals, like USDC)
  - Chainlink price feeds for token -> USD conversion
  - AccessControl for admin/config roles
  - ReentrancyGuard, SafeERC20, checks-effects-interactions
  - Events and custom errors
*/

import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //Definiciones de variables de rol
    //1. CONFIG_ROLE: Rol para configurar tokens y parámetros del banco.
    //2. PAUSER_ROLE: Rol para pausar funciones críticas en caso de emergencia.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Constante para permitir conversiones a USD con 6 decimales (como USDC)
    uint8 public constant USDC_DECIMALS = 6;

    /// @notice Dirección especial del token que representa ETH en los mapeos
    address public constant ETH_ADDRESS = address(0);

    // Errores personalizados
    //1. ZeroDeposit: Se lanza cuando se intenta hacer un depósito de cero.
    //2. BankCapExceeded: Se lanza cuando un depósito excede el límite máximo del banco.
    //3. WithdrawalLimitExceeded: Se lanza cuando un retiro excede el límite permitido por transacción.
    //4. InsufficientBalance: Se lanza cuando un usuario intenta retirar más de su saldo disponible.
    //5. TransferFailed: Se lanza cuando una transferencia de tokens o ETH falla.
    //6. TokenNotRegistered: Se lanza cuando se intenta usar un token no registrado.
    //7. PriceFeedNotSet: Se lanza cuando no se ha configurado un feed de precios para un token.
    //8. InvalidParams: Se lanza cuando se proporcionan parámetros inválidos a una función.
    //9. Unauthorized: Se lanza cuando un usuario sin los permisos adecuados intenta ejecutar una función restringida.
    error ZeroDeposit();
    error BankCapExceeded(uint256 attemptedUsd, uint256 availableUsd);
    error WithdrawalLimitExceeded(uint256 attemptedUsd, uint256 limitUsd);
    error InsufficientBalance(uint256 balance, uint256 requested);
    error TransferFailed();
    error TokenNotRegistered(address token);
    error PriceFeedNotSet(address token);
    error InvalidParams();
    error Unauthorized();

    /// @notice Cap del banco en USD (USDC_DECIMALS)
    uint256 public immutable bankCapUsd;
    /// @notice Límite de retiro por transacción, en USD (USDC_DECIMALS)
    uint256 public immutable withdrawalLimitUsd;
    /// @notice Total USD (USDC_DECIMALS) actualmente depositados (aprox, actualizado en depósito/retiro)
    uint256 public totalUsdDeposited;
    /// @notice Saldo de los usuarios: usuario => direcciónToken => cantidad (unidades nativas del token)
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice Metadatos de tokens registrados
    struct TokenInfo {
        bool registered;
        uint8 decimals; // decimales del token (para ETH usar 18)
        address priceFeed; // feed de precios Chainlink token/USD (puede ser 0 para ETH si se establece ethUsdFeed)
    }
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Feed de precios Chainlink ETH/USD
    AggregatorV3Interface public immutable ethUsdFeed;

    // contadores
    uint256 public depositCount;
    uint256 public withdrawCount;

    //Eventos
    //1. Deposit: Se emite cuando un usuario realiza un depósito.
    //2. Withdraw: Se emite cuando un usuario realiza un retiro.
    //3. TokenRegistered: Se emite cuando se registra un nuevo token.
    //4. TokenUpdated: Se emite cuando se actualizan los metadatos de un token.
    //5. BankCapExceededEvent: Se emite cuando un depósito excede el límite del banco.
    //6. AdminRescue: Se emite cuando un administrador rescata tokens o ETH.
    //7. BankCapChecked: Se emite cuando se verifica si un depósito excedería el límite del banco.
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
    event TokenRegistered(address indexed token, uint8 decimals, address priceFeed);
    event TokenUpdated(address indexed token, uint8 decimals, address priceFeed);
    event BankCapExceededEvent(uint256 attemptedUsd, uint256 availableUsd);
    event AdminRescue(address indexed token, address indexed to, uint256 amount);
    event BankCapChecked(uint256 totalUsdDeposited, uint256 bankCapUsd);

    /// @param _bankCapUsd Limite del banco expresado en USD (e.g. $1,000 = 1_000 * 10**6)
    /// @param _withdrawalLimitUsd Límite de retiro por transacción en USD con USDC_DECIMALS
    /// @param _ethUsdFeed Feed de precios Chainlink ETH / USD
    constructor(uint256 _bankCapUsd, uint256 _withdrawalLimitUsd, address _ethUsdFeed) {
        if (_ethUsdFeed == address(0) || _bankCapUsd == 0) revert InvalidParams();

        // Incializamos el limite del banco y el límite de retiro en USD
        bankCapUsd = _bankCapUsd;
        withdrawalLimitUsd = _withdrawalLimitUsd;
        // Inicializamos el feed de precios ETH/USD --> lo que hace esto es setear la direccion del contrato del feed
        // ergo, tener referencia real del valor de ETH en USD
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);

        //Usamos AccessControl para gestionar roles, esto permite mayor flexibilidad.
        //Lo que generamos aca es usar un smartcontract el cual gestion los roles, permitiendo
        //una segregacion de responsabilidades mas clara.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIG_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // Modificador para funciones que solo pueden ser llamadas por cuentas con el rol CONFIG_ROLE
    modifier onlyConfig() {
        if (!hasRole(CONFIG_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    /// @notice función para registrar un nuevos tokens de criptos en el banco
    function registerToken(address token, uint8 decimals, address priceFeed) external onlyConfig {
        //validamos que el token a registrar no sea la direccion 0 es decir, pertenezca a ERC-20 y no sea ETH nativo
        if (token == address(0)) revert InvalidParams();
        tokenInfo[token] = TokenInfo({registered: true, decimals: decimals, priceFeed: priceFeed});
        emit TokenRegistered(token, decimals, priceFeed);
    }

    /// @notice función para actualizar la metadata de un token cripto registrado
    function updateToken(address token, uint8 decimals, address priceFeed) external onlyConfig {
        if (token == address(0)) revert InvalidParams();
        if (!tokenInfo[token].registered) revert TokenNotRegistered(token);
        tokenInfo[token].decimals = decimals;
        tokenInfo[token].priceFeed = priceFeed;
        emit TokenUpdated(token, decimals, priceFeed);
    }

    /// @notice Función de rescate para que el administrador pueda recuperar tokens o ETH enviados por error al contrato.
    // esto quiere decir que si alguien envia por error tokens o ETH al contrato, el admin puede recuperarlos.
    function adminRescue(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert InvalidParams();
        if (token == ETH_ADDRESS) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit AdminRescue(token, to, amount);
    }

    /// @notice Funcion para depositar ETH nativo en el banco.
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert ZeroDeposit();

        //Convierte el deposito de ETH a su valor en USD.
        uint256 usdValue = _convertToUsd(ETH_ADDRESS, msg.value);

        // valida que, si al depositar no se exceda el limite del banco
        uint256 availableUsd = (bankCapUsd > totalUsdDeposited) ? bankCapUsd - totalUsdDeposited : 0;
        if (usdValue + totalUsdDeposited > bankCapUsd) {
            emit BankCapExceededEvent(usdValue, availableUsd);
            revert BankCapExceeded(usdValue, availableUsd);
        }

        //1. Agregar el monto depositado al saldo del usuario
        //2. Actualizar el total de USD depositados en el banco
        //3. Incrementar el contador de depósitos
        setAccountBalance(msg.sender, msg.value, usdValue);

        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, balances[msg.sender][ETH_ADDRESS], usdValue);
    }

    /// @notice Depositar un token ERC20 en el banco
    /// @param token ERC20 token address (Es la adress del token que se quiere depositar)
    /// @param amount cantidad a depositar (unidades nativas del token)
    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroDeposit();
        
        //Nos fijamos si el token esta registrado y tiene feed de precios
        TokenInfo memory t = tokenInfo[token];
        if (!t.registered) revert TokenNotRegistered(token);
        if (t.priceFeed == address(0)) revert PriceFeedNotSet(token);

        //Usa la interfaz de SafeERC20 para transferir la cripto del token indicado del usuario al contrato
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Convierte el monto a USD
        uint256 usdValue = _convertToUsd(token, amount);

        // valida que, si al depositar no se exceda el limite del banco
        uint256 availableUsd = (bankCapUsd > totalUsdDeposited) ? bankCapUsd - totalUsdDeposited : 0;
        if (usdValue + totalUsdDeposited > bankCapUsd) {
            // revert and refund the token back to user
            // best-effort refund: send token back
            IERC20(token).safeTransfer(msg.sender, amount);
            emit BankCapExceededEvent(usdValue, availableUsd);
            revert BankCapExceeded(usdValue, availableUsd);
        }

        // Effects
        setAccountBalance(msg.sender, amount, usdValue);

        emit Deposit(msg.sender, token, amount, balances[msg.sender][token], usdValue);
    }

    /// @notice Función para retirar fondos del banco, ya sea ETH o tokens ERC20.
    /// @param token token de la cripto a retirar (usar address(0) para ETH)
    /// @param amount cantidad a retirar (unidades nativas del token)
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidParams();

        //Nos fijamos si el token es ETH o ERC20
        //Si es ERC20, validamos que este registrado y tenga feed de precios
        if (token != ETH_ADDRESS) {
            if (!tokenInfo[token].registered) revert TokenNotRegistered(token);
            if (tokenInfo[token].priceFeed == address(0)) revert PriceFeedNotSet(token);
        }

        // Validamos que el usuario tenga saldo suficiente para retirar
        uint256 userBalance = balances[msg.sender][token];
        if (amount > userBalance) revert InsufficientBalance(userBalance, amount);

        // Convertimos el monto a retirar a USD
        uint256 usdValue = _convertToUsd(token, amount);

        // Validamos que el retiro no exceda el límite por transacción
        if (usdValue > withdrawalLimitUsd) revert WithdrawalLimitExceeded(usdValue, withdrawalLimitUsd);

        //1. Actualizamos el saldo del usuario
        //2. Actualizamos el total de USD depositados en el banco
        //3. Incrementamos el contador de retiros
        balances[msg.sender][token] = userBalance - amount;
        totalUsdDeposited = (totalUsdDeposited > usdValue) ? totalUsdDeposited - usdValue : 0;
        withdrawCount += 1;

        //Hacemos la transferencia al usuario, si es ETH usamos call, si es ERC20 usamos SafeERC20
        if (token == ETH_ADDRESS) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdraw(msg.sender, token, amount, balances[msg.sender][token], usdValue);
    }

    // Funciones de lectura PUBLICAS

    /// @notice Dado un usuario y un token, retorna el saldo en el vault
    function getVaultBalance(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }

    /// @notice Dado un token y un monto, retorna el valor aproximado en USD (USDC_DECIMALS) usando los feeds configurados.
    /// @dev Reverts if token feed not configured (except ETH uses ethUsdFeed)
    function convertToUsdView(address token, uint256 amount) external view returns (uint256) {
        return _convertToUsd(token, amount);
    }

    /// @notice funcion para determina si un deposito excederia el limite del banco
    /// @param token token de la cripto a depositar (usar address(0) para ETH)
    /// @param amount cantidad a depositar (unidades nativas del token)
    function wouldExceedBankCap(address token, uint256 amount) external view returns (bool, uint256, uint256) {
        uint256 usd = _convertToUsd(token, amount);
        uint256 availableUsd = (bankCapUsd > totalUsdDeposited) ? bankCapUsd - totalUsdDeposited : 0;
        return (usd + totalUsdDeposited > bankCapUsd, usd, availableUsd);
    }

    // Funciones interntas PRIVADAS
    /// @notice Función interna para convertir un monto de un token a su valor en USD usando Chainlink feeds.
    function _convertToUsd(address token, uint256 amount) internal view returns (uint256) {
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

    /// @notice Función interna para actualizar el saldo de un usuario y el total USD depositados.
    function setAccountBalance(address user, uint256 amount, uint256 usdValue) internal {
        balances[user][ETH_ADDRESS] = amount;
        totalUsdDeposited += usdValue;
        depositCount += 1;
    }

    //Fallback si se envia ETH sin llamar a depositETH
    receive() external payable {
        revert ZeroDeposit();
    }

    //Fallback si se envia ETH con datos invalidos
    fallback() external payable {
        revert ZeroDeposit(); 
    }
