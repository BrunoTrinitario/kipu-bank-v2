# KipuBank v2 - Smart Contract Banking Solution

## Descripción

KipuBank v2 es una evolución completa del contrato inteligente original, transformándolo en una solución bancaria descentralizada de nivel producción. Este proyecto implementa un sistema multi-token con contabilidad interna en USD, integración de oráculos Chainlink, control de acceso basado en roles y múltiples capas de seguridad.

El contrato permite a los usuarios depositar y retirar tanto ETH nativo como tokens ERC-20, manteniendo una contabilidad unificada en USD para todos los activos, similar a sistemas bancarios tradicionales.

## Objetivos del Proyecto

Este proyecto representa la culminación de un proceso de aprendizaje en desarrollo de contratos inteligentes avanzados, demostrando la capacidad de:

- Identificar y resolver limitaciones en contratos existentes
- Aplicar patrones de diseño seguros y recursos avanzados de Solidity
- Implementar arquitectura escalable y mantenible
- Integrar servicios externos (oráculos Chainlink)
- Seguir buenas prácticas de documentación y desarrollo profesional

## Características Principales

### Control de Acceso Basado en Roles
- **AccessControl de OpenZeppelin**: Sistema de permisos granular y flexible
- **Roles definidos**:
  - `DEFAULT_ADMIN_ROLE`: Administración completa del contrato
  - `CONFIG_ROLE`: Configuración de tokens y parámetros
  - `PAUSER_ROLE`: Capacidad de pausar operaciones en emergencias

### Soporte Multi-Token
- Depósitos y retiros de **ETH nativo** mediante `depositETH()`
- Depósitos y retiros de **tokens ERC-20** mediante `depositERC20()` y `withdraw()`
- Sistema de registro dinámico de tokens con `registerToken()` y `updateToken()`
- Uso de `address(0)` como identificador especial para ETH nativo

### Contabilidad Interna en USD
- **Conversión automática** de todos los activos a USD (6 decimales, formato USDC)
- **Tracking centralizado** del valor total depositado en `totalUsdDeposited`
- **Bank Cap en USD**: Límite máximo del banco expresado en dólares, independiente del token depositado
- **Límite de retiro por transacción** en USD para seguridad adicional

### Integración con Oráculos Chainlink
- **Data Feeds** para conversión en tiempo real de precios token/USD
- Soporte para múltiples feeds de precios (ETH/USD, token/USD)
- Manejo robusto de decimales de feeds (típicamente 8 decimales)
- Validación de precios positivos antes de procesar transacciones

### Conversión Avanzada de Decimales
- Manejo inteligente de diferentes precisiones decimales:
  - ETH: 18 decimales
  - Tokens ERC-20: variable (6, 8, 18, etc.)
  - Feeds Chainlink: típicamente 8 decimales
  - USD interno: 6 decimales (estándar USDC)
- Conversiones precisas sin pérdida de información

### Seguridad y Eficiencia

#### Patrón Checks-Effects-Interactions
```solidity
// 1. Checks: Validaciones
if (amount == 0) revert ZeroDeposit();
if (!tokenInfo[token].registered) revert TokenNotRegistered(token);

// 2. Effects: Actualización de estado
balances[msg.sender][token] += amount;
totalUsdDeposited += usdValue;

// 3. Interactions: Llamadas externas
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
```

#### Optimizaciones de Gas
- Variables `immutable` para valores fijos (bankCapUsd, withdrawalLimitUsd, ethUsdFeed)
- Variables `constant` para direcciones especiales (ETH_ADDRESS, USDC_DECIMALS)
- Errores personalizados en lugar de strings (ahorro ~90% de gas)
- Uso eficiente de memoria con `memory` vs `storage`

#### Protección contra Reentrancy
- **ReentrancyGuard de OpenZeppelin** en todas las funciones de transferencia
- Modificador `nonReentrant` en `depositETH()`, `depositERC20()` y `withdraw()`

#### Transferencias Seguras
- **SafeERC20** para todos los transfers de tokens ERC-20
- Patrón `call` para transferencias de ETH nativo con verificación de éxito
- Revert automático en caso de fallo de transferencia

### Eventos Completos
```solidity
event Deposit(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 newVaultBalance, uint256 usdValue);
event TokenRegistered(address indexed token, uint8 decimals, address priceFeed);
event TokenUpdated(address indexed token, uint8 decimals, address priceFeed);
event BankCapExceededEvent(uint256 attemptedUsd, uint256 availableUsd);
event AdminRescue(address indexed token, address indexed to, uint256 amount);
```

### Errores Personalizados
```solidity
error ZeroDeposit();
error BankCapExceeded(uint256 attemptedUsd, uint256 availableUsd);
error WithdrawalLimitExceeded(uint256 attemptedUsd, uint256 limitUsd);
error InsufficientBalance(uint256 balance, uint256 requested);
error TransferFailed();
error TokenNotRegistered(address token);
error PriceFeedNotSet(address token);
error InvalidParams();
error Unauthorized();
```

## Estructura del Proyecto

```
kipu-bankV2/
├── src/
│   ├── kipu-bankv1.sol          # Versión original (referencia)
│   └── kipu-bankv2.sol          # Versión mejorada con todas las features
├── test/
│   └── Counter.t.sol            # Tests (pendiente de actualización)
├── script/
│   └── Counter.s.sol            # Scripts de despliegue
├── lib/
│   ├── openzeppelin-contracts/  # AccessControl, ReentrancyGuard, SafeERC20
│   ├── chainlink-brownie-contracts/ # AggregatorV3Interface
│   └── forge-std/               # Testing utilities
├── foundry.toml                 # Configuración de Foundry
└── README_BANK2.md             # Este documento
```

## Funcionalidades Principales

### Para Usuarios

#### `depositETH()`
Deposita ETH nativo en el banco.
- **Payable**: Acepta ETH enviado en la transacción
- **Conversión automática** a USD usando Chainlink ETH/USD feed
- **Validación de bank cap** antes de aceptar el depósito
- **Protección reentrancy**

```solidity
// Ejemplo de uso
kipuBank.depositETH{value: 1 ether}();
```

#### `depositERC20(address token, uint256 amount)`
Deposita tokens ERC-20 registrados.
- **Requiere aprobación previa** del token al contrato
- **Validación de token registrado** y feed de precios configurado
- **Conversión automática** a USD usando el feed específico del token
- **Reembolso automático** si excede el bank cap

```solidity
// Ejemplo de uso
token.approve(address(kipuBank), amount);
kipuBank.depositERC20(address(token), amount);
```

#### `withdraw(address token, uint256 amount)`
Retira fondos depositados (ETH o ERC-20).
- **Validación de saldo** suficiente
- **Límite por transacción** en USD
- **Transferencia segura** con verificación de éxito

```solidity
// Retirar ETH
kipuBank.withdraw(address(0), 0.5 ether);

// Retirar ERC-20
kipuBank.withdraw(address(token), amount);
```

#### `getVaultBalance(address user, address token)`
Consulta el saldo de un usuario para un token específico.

```solidity
uint256 balance = kipuBank.getVaultBalance(msg.sender, address(0)); // ETH
```

#### `convertToUsdView(address token, uint256 amount)`
Obtiene el valor en USD de una cantidad de tokens sin ejecutar transacción.

```solidity
uint256 usdValue = kipuBank.convertToUsdView(address(0), 1 ether);
```

#### `wouldExceedBankCap(address token, uint256 amount)`
Verifica si un depósito excedería el límite del banco.

```solidity
(bool exceeds, uint256 usd, uint256 available) = kipuBank.wouldExceedBankCap(address(0), 10 ether);
```

### Para Administradores (CONFIG_ROLE)

#### `registerToken(address token, uint8 decimals, address priceFeed)`
Registra un nuevo token ERC-20 en el sistema.

```solidity
// Registrar USDC con su feed de precios
kipuBank.registerToken(
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
    6,                                          // 6 decimales
    0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6  // USDC/USD Chainlink feed
);
```

#### `updateToken(address token, uint8 decimals, address priceFeed)`
Actualiza la configuración de un token registrado.

### Para Administradores (DEFAULT_ADMIN_ROLE)

#### `adminRescue(address token, address to, uint256 amount)`
Rescata tokens o ETH enviados accidentalmente al contrato.
- **Función de emergencia** para fondos enviados por error
- **No afecta** los balances de usuarios registrados

## Seguridad

### Medidas Implementadas

1. **Control de Acceso**: Roles granulares para diferentes niveles de permisos
2. **ReentrancyGuard**: Protección contra ataques de reentrada
3. **SafeERC20**: Manejo seguro de tokens ERC-20 no estándar
4. **Checks-Effects-Interactions**: Patrón de seguridad estándar
5. **Validaciones exhaustivas**: Múltiples capas de verificación
6. **Errores descriptivos**: Facilitan debugging y auditorías
7. **Eventos completos**: Trazabilidad total de operaciones
8. **Immutable/Constant**: Variables críticas inmutables
9. **Price validation**: Verificación de precios positivos de Chainlink
10. **Fallback protection**: `receive()` y `fallback()` con revert

### Consideraciones de Seguridad

**Dependencia de Oráculos**: El sistema depende de la disponibilidad y precisión de Chainlink feeds

**Price staleness**: No se implementa validación de frescura de precios (considerar para producción)

**Pausability**: El rol PAUSER_ROLE está definido pero no implementado (considerar CircuitBreaker pattern)

## Instalación y Uso

### Requisitos Previos
```bash
# Instalar Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verificar instalación
forge --version
```

### Instalación
```bash
# Clonar el repositorio
git clone https://github.com/BrunoTrinitario/kipu-bank-v2.git
cd kipu-bankV2

# Instalar dependencias
forge install
```

### Compilación
```bash
forge build
```

### Testing
```bash
forge test
forge test -vvv  # Verbose output
forge test --gas-report  # Gas report
```

### Despliegue

#### Sepolia Testnet
```bash
# Configurar variables de entorno
export SEPOLIA_RPC_URL="your_alchemy_or_infura_url"
export PRIVATE_KEY="your_private_key"
export ETHERSCAN_API_KEY="your_etherscan_key"

# Desplegar
forge create --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --constructor-args 1000000000000 500000000000 0x694AA1769357215DE4FAC081bf1f309aDC325306 \
    --verify \
    src/kipu-bankv2.sol:KipuBank

# Parámetros del constructor:
# 1. bankCapUsd: 1,000,000 USD (1000000 * 10^6)
# 2. withdrawalLimitUsd: 500,000 USD (500000 * 10^6)
# 3. ethUsdFeed: Chainlink ETH/USD feed en Sepolia
```

## Mejoras Implementadas vs Versión Original

| Aspecto | KipuBank v1 | KipuBank v2 |
|---------|-------------|-------------|
| **Tokens soportados** | Solo ETH nativo | ETH + múltiples ERC-20 |
| **Contabilidad** | Por token | USD unificado |
| **Oráculos** | ❌ No | ✅ Chainlink Feeds |
| **Control de acceso** | Solo owner | AccessControl con roles |
| **Seguridad** | Básica | ReentrancyGuard + SafeERC20 |
| **Errores** | Strings | Custom errors (gas eficiente) |
| **Eventos** | Básicos | Completos e indexados |
| **Decimales** | Fijo | Conversión dinámica |
| **Bank cap** | En tokens | En USD |
| **Límite retiro** | ❌ No | ✅ Por transacción en USD |
| **Admin rescue** | ❌ No | ✅ Función de emergencia |
| **Extensibilidad** | Limitada | Alta (tokens dinámicos) |

## Casos de Uso

### Caso 1: Usuario deposita ETH
```solidity
// 1. Usuario envía 1 ETH cuando ETH = $2000
kipuBank.depositETH{value: 1 ether}();

// Internamente:
// - Se obtiene precio ETH/USD de Chainlink: $2000
// - Se calcula USD: 1 ETH * $2000 = $2000 USD
// - Se verifica bank cap: $2000 + totalDeposited < bankCapUsd
// - Se actualiza balance[user][address(0)] += 1 ether
// - Se actualiza totalUsdDeposited += 2000 * 10^6
```

### Caso 2: Usuario deposita USDC
```solidity
// 1. Usuario aprueba 1000 USDC
usdc.approve(address(kipuBank), 1000 * 10**6);

// 2. Usuario deposita
kipuBank.depositERC20(address(usdc), 1000 * 10**6);

// Internamente:
// - Se obtiene precio USDC/USD de Chainlink: $1.00
// - Se calcula USD: 1000 USDC * $1.00 = $1000 USD
// - Se transfiere USDC del usuario al contrato (SafeERC20)
// - Se actualiza balance[user][usdc] += 1000 * 10^6
// - Se actualiza totalUsdDeposited += 1000 * 10^6
```

### Caso 3: Admin registra nuevo token
```solidity
// Admin registra DAI
kipuBank.registerToken(
    0x6B175474E89094C44Da98b954EedeAC495271d0F, // DAI mainnet
    18,                                          // 18 decimales
    0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9  // DAI/USD feed
);

// Ahora los usuarios pueden depositar DAI
```

## Recursos y Referencias

### Chainlink Price Feeds
- [Documentación oficial](https://docs.chain.link/data-feeds)
- [Direcciones de contratos](https://docs.chain.link/data-feeds/price-feeds/addresses)
- ETH/USD Sepolia: `0x694AA1769357215DE4FAC081bf1f309aDC325306`

### OpenZeppelin
- [AccessControl](https://docs.openzeppelin.com/contracts/4.x/access-control)
- [ReentrancyGuard](https://docs.openzeppelin.com/contracts/4.x/api/security#ReentrancyGuard)
- [SafeERC20](https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#SafeERC20)

### Foundry
- [Book](https://book.getfoundry.sh/)
- [Cheatcodes](https://book.getfoundry.sh/cheatcodes/)

## Contribuciones

Este proyecto es parte de un examen final académico. Para sugerencias o mejoras:

1. Fork el repositorio
2. Crea una branch (`git checkout -b feature/mejora`)
3. Commit tus cambios (`git commit -am 'Agrega nueva feature'`)
4. Push a la branch (`git push origin feature/mejora`)
5. Abre un Pull Request

## Licencia

MIT License - ver archivo LICENSE para más detalles

## Autor

**Bruno Trinitario**
- GitHub: [@BrunoTrinitario](https://github.com/BrunoTrinitario)
- Proyecto: [kipu-bank-v2](https://github.com/BrunoTrinitario/kipu-bank-v2)

## Agradecimientos

- Equipo de Chainlink por los oráculos descentralizados
- OpenZeppelin por los contratos seguros y auditados
- Foundry por las herramientas de desarrollo
- Comunidad de Solidity por las mejores prácticas

---

**Nota**: Este contrato es un proyecto educativo. Para uso en producción, se recomienda una auditoría de seguridad profesional completa.
