// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract KipuBank {

    // @notice Error asociado a intenatar hacer un deposito de de 0
    error ZeroDeposit();

    // @notice Error asociado a intentar depositar mas de lo que el banco puede soportar
    // @param attempted: Cuanto se itnento depositar
    // @param available: Cuando queda disponible en el banco para despositar
    error BankCapExceeded(uint256 attempted, uint256 available);

    /// @notice Error asociado al intento de retirar mas de permitido
    /// @param attempted: intento de retiro
    /// @param limit: límite por transacción
    error WithdrawalLimitExceeded(uint256 attempted, uint256 limit);

    /// @notice Error asociado al intentar retirar mas de lo que se tiene en la cuenta
    /// @param balance: saldo actual
    /// @param requested: solicitado para retirar
    error InsufficientBalance(uint256 balance, uint256 requested);

    /// @notice Fallo la transferencia desde el contrato al usuario
    error TransferFailed();

    /// @notice Fallo al intentar usar la funcion deposit directamente
    error UseDeposit();

    /// @notice Reentrada detectada
    error ReentrantCall();

    /// @notice Variable que determina el limite de fondos que el banco puede guardar
    uint256 public immutable bankCap;

    /// @notice Límite máximo por transacción para retiros (inmutable)
    uint256 public immutable withdrawalLimit;

    /// @notice Mapa de la forma [direccion de cuenta -> balance]
    mapping(address => uint256) private vaults;

    /// @notice Número total de depósitos realizados en el contrato
    uint256 public depositCount;

    /// @notice Número total de retiros realizados en el contrato
    uint256 public withdrawCount;

    /// @notice Flag de entrada
    bool private locked;

    /// @notice Emitido cuando un usuario deposita con éxito
    /// @param user: dirección del depositante
    /// @param amount: cantidad depositada (wei)
    /// @param newVaultBalance: saldo del usuario después del depósito
    event Deposit(address indexed user, uint256 amount, uint256 newVaultBalance);

    /// @notice Emitido cuando un usuario retira con éxito
    /// @param user: dirección del que retira
    /// @param amount: cantidad retirada (wei)
    /// @param newVaultBalance: saldo del usuario después del retiro
    event Withdraw(address indexed user, uint256 amount, uint256 newVaultBalance);

    /// @param _bankCap: límite global de fondos (wei)
    /// @param _withdrawalLimit: límite por transacción para retiros (wei)
    constructor(uint256 _bankCap, uint256 _withdrawalLimit) {
        bankCap = _bankCap;
        withdrawalLimit = _withdrawalLimit;
        locked = false;
    }

    /// @notice Evita reentradas - haciendo el cambio de flag NO ATOMICO
    modifier nonReentrant() {
        if (locked) revert ReentrantCall();
        locked = true;
        _;
        locked = false;
    }

    /// @notice Valida que el depósito no provoque que el contrato supere bankCap
    /// @param value: cantidad entrante (wei)
    modifier underBankCap(uint256 value) {
        // Se ler esta el value (lo depositado) ya que cuando se ejecuta la funcion
        // "deposit" al ser Payable, ya se suma lo hecho, por eso se le resta eso
        uint256 prevBalance = address(this).balance - value; // saldo antes del depósito actual
        if (prevBalance + value > bankCap) {
            uint256 available = bankCap - prevBalance;
            //si falla se devuelve lo pagado al usuario
            revert BankCapExceeded(value, available);
        }
        _;
    }

    /// @notice Deposita ETH en la bóveda personal del remitente.
    /// @dev Requiere msg.value > 0 y que el depósito no exceda la capacidad global (bankCap).
    function deposit() external payable underBankCap(msg.value){
        if (msg.value == 0) revert ZeroDeposit();

        //Le suma lo depositado al map
        vaults[msg.sender] += msg.value;
        _incrementDepositCount();

        emit Deposit(msg.sender, msg.value, vaults[msg.sender]);
    }

    /// @notice Retira hasta `withdrawalLimit` por transacción desde la propia bóveda.
    /// @param amount: cantidad a retirar (wei)
    function withdraw(uint256 amount) external nonReentrant {
        if (amount > withdrawalLimit) revert WithdrawalLimitExceeded(amount, withdrawalLimit);

        uint256 userBalance = vaults[msg.sender]; //valor actual de la boveda del usuario
        if (amount > userBalance) revert InsufficientBalance(userBalance, amount);

        // Checks-effects-interactions:
        // Effects
        vaults[msg.sender] = userBalance - amount;
        _incrementWithdrawCount();

        // Interaction: transfer seguro usando call
        _safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, vaults[msg.sender]);
    }

    /// @notice Obtiene el saldo de la bóveda de `user`.
    /// @param user dirección a consultar
    /// @return saldo en wei
    function getVaultBalance(address user) external view returns (uint256) {
        return vaults[user];
    }

    /// @notice Devuelve el saldo total actual guardado en el contrato (wei).
    /// @return total balance del contrato
    function totalHoldings() external view returns (uint256) {
        return address(this).balance;
    }


    /// @dev Incrementa el contador de depósitos (privada)
    function _incrementDepositCount() private {
        depositCount += 1;
    }

    /// @dev Incrementa el contador de retiros (privada)
    function _incrementWithdrawCount() private {
        withdrawCount += 1;
    }

    /// @dev Transferencia nativa segura usando call pattern. Revert con TransferFailed si falla.
    /// @param to: destino
    /// @param amount: cantidad a enviar (wei)
    function _safeTransfer(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice No permitir envíos directos por seguridad; usar deposit()
    receive() external payable {
        revert UseDeposit();
    }

    fallback() external payable {
        revert UseDeposit();
    }
}
