KipuBank v3 — Documentación técnica

Descripción

KipuBank v3 es la evolución modular del proyecto KipuBank: refactoriza la lógica monolítica de la versión anterior en módulos especializados, introduce swaps automáticos a USDC como moneda de contabilidad interna y mejora la separación de responsabilidades mediante un gestor de roles. El objetivo es acercar el contrato a un diseño más cercano a producción manteniendo simplicidad educativa.

Por qué importa

Este repositorio muestra cómo transformar un contrato existente en una arquitectura modular y extendible. En un entorno real, separar responsabilidades (roles, swaps, contabilidad) facilita auditoría, testing, despliegue y evolución del sistema.

Objetivos del README

- Explicar la arquitectura y los nuevos módulos introducidos en v3.
- Documentar el flujo de depósito/retirada y la contabilidad en USDC.
- Enumerar los cambios clave respecto a v2.
- Incluir instrucciones de uso, despliegue y recomendaciones de seguridad y testing.

Novedades principales en v3

1. Modularización
   - `RoleManager` (src/libs/roleManager.sol): Extrae la gestión de roles basada en OpenZeppelin AccessControl a un módulo separado. Proporciona funciones helper para asignar/revocar roles y eventos relacionados.
   - `tokenSwapManager` (src/libs/tokenSwapManager.sol): Módulo pensado para realizar swaps via Uniswap (router) y transformar tokens entrantes a USDC. Está diseñado para que el contrato principal delegue la lógica de intercambio.
   - `kipu-bankv3.sol`: Contrato principal que compone `RoleManager` y `TokenManager` (o módulos equivalentes). En v3 los depósitos son convertidos a USDC y la contabilidad interna se mantiene en USDC.

2. Contabilidad en USDC
   - En v3, los depósitos (ETH o ERC-20) se swapean a USDC y los saldos de usuario se almacenan en unidades USDC (1 USDC ≈ 1 USD, 6 decimales).
   - Esto unifica el seguimiento del `bankCap` y simplifica límites en USD.

3. Flujo de depósitos y retiros (alto nivel)
   - Deposit ETH: el usuario llama `depositETH()` con ETH. El módulo de swap convierte ETH a USDC; el contrato actualiza el balance del usuario en USDC.
   - Deposit ERC-20: si el token es USDC se almacena directamente; si no, se transfieren tokens al contrato y se swapea a USDC vía `tokenSwapManager`.
   - Retiro: las retiradas se hacen en USDC (en la implementación actual) y se transfieren USDC al usuario. (Nota: diseño admite extender para ofrecer swap inverso al token original si se desea.)

4. Control de acceso
   - `RoleManager` expone roles como `DEFAULT_ADMIN_ROLE`, `CONFIG_ROLE` y `PAUSER_ROLE` y wrappers para operar los permisos.
   - El contrato principal usa modifiers como `onlyAdmin` para funciones sensibles (rescate, configuración).

5. Integración con oráculos y precio
   - Se mantiene dependencia de Chainlink (ej. feed ETH/USD) principalmente para casos de conversión directa o checks adicionales.
   - En v3 la conversión principal se hace mediante swaps a USDC, pero se conservan utilidades para conversión y chequeo de límites.

Arquitectura y archivos relevantes

- `src/kipu-bankv3.sol` — Contrato principal. Integra `RoleManager` y módulos relacionados. Mantiene inmubles como `bankCapUsd` y `withdrawalLimitUsd`.
- `src/libs/roleManager.sol` — Gestión de roles y eventos.
- `src/libs/tokenSwapManager.sol` — Lógica de swap (Uniswap Router). Responsable de convertir tokens/ETH a USDC.
- `src/libs/...` — Otros módulos (p. ej. `tokenManager.sol` si existe) que separan la lógica de tokens, contabilidad o swaps.

Flujo de llamadas (depósito ERC-20 que no es USDC)

1. Usuario `approve` + `depositERC20(token, amount)`.
2. Contrato principal `safeTransferFrom` del token al contrato.
3. Llama a `tokenSwapManager.swapTokenForUSDC(token, amount)`.
4. Recibe USDC y actualiza `balances[user]` en USDC.
5. Emite eventos `Deposit` con valores en USDC.

Recomendaciones de diseño y limitaciones conocidas

- Validación de pares / existence check: `tokenSwapManager` depende de que exista un par token/USDC en el factory. Hay que implementar fallback (ruta alternativa) y manejo claro cuando no existe el par.
- Slippage y mínimos: el módulo debería recibir parámetros de slippage / minOut para evitar pérdidas inesperadas.
- Aprovals y seguridad: revisar límites de allowance y evitar aprobaciones infinitas cuando no sea necesario.
- Pruebas de integración: tests que simulen swaps en un fork o en un entorno con mocks del router.
- Auditoría de `tokenSwapManager`: el intercambio introduce riesgos (frontrunning, slippage, pares maliciosos). Recomendable auditoría independiente.
- Gestión de precios: la estrategia de swap a USDC depende de la liquidez de los pares; mantener oráculos como chequeo adicional es buena práctica.

Seguridad y mitigaciones

- `ReentrancyGuard` para funciones que transfieren fondos.
- `SafeERC20` para transferencias de tokens.
- Roles para limitar funciones administrativas (rescate, registro de pares, ajustes).
- Uso de `immutable`/`constant` en parámetros de constructor cuando aplica.
- Registrar y auditar eventos críticos: `Deposit`, `Withdraw`, `BankCapExceededEvent`, `AdminRescue`.

Instalación, compilación y tests

Requisitos

- Foundry (recommended) o framework Solidity equivalente.
- Dependencias definidas en `lib/` (OpenZeppelin, Uniswap v2 Periphery/Core, Chainlink feeds).

Pasos rápidos

```bash
# Clonar y entrar en el repo
git clone https://github.com/BrunoTrinitario/kipu-bank-v2.git
cd kipu-bankV2

# Instalar dependencias (foundry)
forge install

# Compilar
forge build

# Ejecutar tests (implementar mocks necesarios para swaps)
forge test
```

Despliegue (nota: actualizar RPC/keys según red)

- Constructor de `kipu-bankv3` requiere parámetros como `bankCapUsd`, `withdrawalLimitUsd`, `ethUsdFeed`, y las direcciones del router + USDC para `tokenSwapManager` si corresponde.
- Verificar antes de desplegar: direcciones del router, dirección USDC, permisos y roles administrativos iniciales.

Ejemplo: despliegue en testnet (conceptual)

```bash
export RPC_URL="https://..."
export PRIVATE_KEY="..."

forge create --rpc-url $RPC_URL --private-key $PRIVATE_KEY src/kipu-bankv3.sol:KipuBank --constructor-args <bankCap> <withdrawalLimit> <ethUsdFeed> <routerAddr> <usdcAddr>
```

Se recomienda: desplegar primero `tokenSwapManager` (si es un contrato independiente), luego configurar las direcciones en el constructor o via `set` desde la cuenta `CONFIG_ROLE`.

Secciones para documentación adicional (próximos pasos)

- Tests de integración con Uniswap (fork mainnet o mocks).
- Documentar la API pública (listado de funciones con parámetros y errores personalizados).
- Ejemplos de scripts de despliegue y verificación en Etherscan.

Conclusión

KipuBank v3 muestra una evolución hacia una arquitectura modular y orientada a producción: centraliza contabilidad en USDC, añade un módulo de swaps y mejora la gestión de roles. Aun así, agrega complejidad operativa (dependencia de AMM, pares y rutas) que debe ser cubierta con pruebas y auditoría para su uso en entornos reales.


---

Archivo generado a partir de `README_BANK2.md` y los nuevos módulos añadidos en la rama `kipu-bankv3`.
