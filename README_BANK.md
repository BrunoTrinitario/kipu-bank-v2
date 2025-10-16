# BankVault Smart Contract
## Descripción

Este proyecto implementa un contrato inteligente tipo banco de depósitos nativos (ETH/BNB/MATIC según red) con control de límites y seguridad.
Los usuarios pueden depositar y retirar fondos, mientras que el administrador define un límite máximo total (bank cap) que no puede ser superado.

## Características

Depósitos nativos seguros usando el patrón call.

Restricción de depósitos y retiros a través del bank cap.

Manejo de balances individuales con `mapping(address => uint256)`.

Protección contra envíos directos de fondos mediante `receive()` y `fallback()`.

Retiro seguro con revert si la transferencia falla.

Funcionalidades principales

- `deposit()`
Permite a un usuario enviar fondos al contrato. Aplica la validación del límite del banco mediante el modificador underBankCap.
Actualiza el balance del remitente en el mapping vaults.

- `withdraw(uint256 amount)`
Permite retirar fondos previamente depositados. Verifica que el usuario tenga suficiente balance y usa _safeTransfer para enviar los fondos.

- `_safeTransfer(address to, uint256 amount)`
Función privada que implementa la transferencia segura de fondos usando el patrón call.
Revertirá con TransferFailed si la operación no tiene éxito.

- `receive()` y `fallback()`
Ambas funciones rechazan envíos directos de ETH/MATIC/BNB al contrato. Los usuarios deben usar `deposit()` para interactuar correctamente.

## Seguridad

- El contrato evita que se acumulen fondos no contabilizados gracias al revert en `receive()` y `fallback()`.

- Control de retiros y depósitos garantizado mediante verificación de balance y uso de underBankCap.

- Uso de revert con errores personalizados para reducir costos de gas y mejorar la legibilidad.

## Uso esperado

- El administrador despliega el contrato y define el bankCap.

- Los usuarios llaman a deposit() para guardar fondos en la bóveda.

- Cada usuario puede consultar y retirar su balance mediante withdraw().

- Los depósitos no pueden exceder el límite total definido.