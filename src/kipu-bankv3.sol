// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./libs/roleManager.sol";
import "./libs/tokenSwapManager.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract KipuBank is RoleManager, ReentrancyGuard, TokenManager {
    using SafeERC20 for IERC20;

    //Definiciones de variables de rol
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

    /// @notice Cap del banco en USD (USDC_DECIMALS)
    uint256 public immutable bankCapUsd;
    /// @notice Límite de retiro por transacción, en USD (USDC_DECIMALS)
    uint256 public immutable withdrawalLimitUsd;
    /// @notice Total USD (USDC_DECIMALS) actualmente depositados (aprox, actualizado en depósito/retiro)
    uint256 public totalUsdDeposited;
    /// @notice Saldo de los usuarios: usuario => cantidad (unidades nativas del token)
    mapping(address => uint256) private balances;
    AggregatorV3Interface public immutable ethUsdFeed;
    //Address del token USDC
    address public usdc;


    // contadores
    uint256 public depositCount;
    uint256 public withdrawCount;

    //Eventos
    //1. Deposit: Se emite cuando un usuario realiza un depósito.
    //2. Withdraw: Se emite cuando un usuario realiza un retiro.
    //3. BankCapExceededEvent: Se emite cuando un depósito excede el límite del banco.
    //4. AdminRescue: Se emite cuando un administrador rescata tokens o ETH.
    //5. BankCapChecked: Se emite cuando se verifica si un depósito excedería el límite del banco.
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
    event BankCapExceededEvent(uint256 attemptedUsd, uint256 availableUsd);
    event AdminRescue(address indexed token, address indexed to, uint256 amount);
    event BankCapChecked(uint256 totalUsdDeposited, uint256 bankCapUsd);

    /// @param _bankCapUsd Limite del banco expresado en USD (e.g. $1,000 = 1_000 * 10**6)
    /// @param _withdrawalLimitUsd Límite de retiro por transacción en USD con USDC_DECIMALS
    /// @param _ethUsdFeed Feed de precios Chainlink ETH / USD
    constructor(uint256 _bankCapUsd, uint256 _withdrawalLimitUsd, address _ethUsdFeed, address _usdc) RoleManager() TokenManager(_usdc) {
        if (_ethUsdFeed == address(0) || _bankCapUsd == 0) revert InvalidParams();
        // Incializamos el limite del banco y el límite de retiro en USD
        bankCapUsd = _bankCapUsd;
        withdrawalLimitUsd = _withdrawalLimitUsd;
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        usdc = _usdc;
    }

    /// @notice Función de rescate para que el administrador pueda recuperar tokens o ETH enviados por error al contrato.
    // esto quiere decir que si alguien envia por error tokens o ETH al contrato, el admin puede recuperarlos.
    function adminRescue(address token, address to, uint256 amount) external onlyAdmin {
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

        //Swapea el ETH recibido a USDC usando tu módulo de swap
        uint256 usdcReceived = swapETHForUSDC(msg.value);
    
        //Convertimos los USDC recibidos a su valor en USD (1 USDC ≈ 1 USD)
        uint256 usdValue = usdcReceived;
    
        //Validar que no se supere el límite del banco
        uint256 availableUsd = (bankCapUsd > totalUsdDeposited) ? bankCapUsd - totalUsdDeposited : 0;
        if (usdValue + totalUsdDeposited > bankCapUsd) {
            emit BankCapExceededEvent(usdValue, availableUsd);
            revert BankCapExceeded(usdValue, availableUsd);
        }
    
        //Actualizar balances y total global
        setAccountBalance(msg.sender, usdValue, usdValue);
    
        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, balances[msg.sender], usdValue);
    }

    /// @notice Depositar un token ERC20 en el banco
    /// @param token ERC20 token address (Es la adress del token que se quiere depositar)
    /// @param amount cantidad a depositar (unidades nativas del token)
    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroDeposit();

        uint256 usdcReceived;

        // 1. Transferencia y Swap
        if (token == usdc) {
            IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
            usdcReceived = amount;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            // Realizamos el swap. Si luego hacemos revert, este swap SE DESHACE.
            usdcReceived = swapTokenForUSDC(token, amount);
        }

        // 2. Valoración
        uint256 usdValue = usdcReceived;

        // 3. Validación del Bank Cap
        if (usdValue + totalUsdDeposited > bankCapUsd) {
            uint256 availableUsd = (bankCapUsd > totalUsdDeposited) 
                ? bankCapUsd - totalUsdDeposited 
                : 0;

            // ALERTA: Al ejecutar este revert, la EVM deshace todos los cambios anteriores.
            // 1. Los USDC del swap vuelven al Exchange.
            // 2. El token original vuelve al contrato.
            // 3. El token original vuelve del contrato a la billetera del usuario.
            revert BankCapExceeded(usdValue, availableUsd);
        }

        // 4. Actualización (Solo llegamos aquí si NO se revirtió)
        totalUsdDeposited += usdValue;
        setAccountBalance(msg.sender, usdValue, usdValue);

        emit Deposit(msg.sender, token, amount, balances[msg.sender], usdValue);
    }

    /// @notice Función para retirar fondos del banco, ya sea ETH o tokens ERC20.
    /// @param token token de la cripto a retirar (usar address(0) para ETH)
    /// @param amount cantidad a retirar (en usdc)
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidParams();

        // Validamos que el usuario tenga suficiente USDC
        uint256 userBalanceUSDC = balances[msg.sender];
        if (amount > userBalanceUSDC) revert InsufficientBalance(userBalanceUSDC, amount);

        // Convertimos el monto a USD (1 USDC ≈ 1 USD)
        uint256 usdValue = amount;

        // Validamos límite por retiro
        if (usdValue > withdrawalLimitUsd)
            revert WithdrawalLimitExceeded(usdValue, withdrawalLimitUsd);

        // Actualizamos balances y total global
        balances[msg.sender] = userBalanceUSDC - amount;
        totalUsdDeposited = (totalUsdDeposited > usdValue) ? totalUsdDeposited - usdValue : 0;
        withdrawCount += 1;

        // Transferimos los USDC directamente al usuario
        IERC20(usdc).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, usdc, amount, balances[msg.sender], usdValue);
    }

    // Funciones de lectura PUBLICAS
    /// @notice Dado un usuario y un token, retorna el saldo en el vault
    function getVaultBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    /// @notice Función interna para actualizar el saldo de un usuario y el total USD depositados.
    function setAccountBalance(address user, uint256 amount, uint256 usdValue) internal {
        balances[user] = amount;
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

}