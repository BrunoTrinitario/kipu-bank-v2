# Informe de Análisis de Amenazas – KipuBank V3

## 1. Descripción general de cómo funciona KipuBank V3

KipuBank V3 es un contrato de "banco" on-chain que recibe depósitos de usuarios y mantiene contabilidad interna en USDC. A diferencia de versiones anteriores, V3:

- Usa USDC como token de contabilidad interna (1 USDC ≈ 1 USD, 6 decimales).
- Acepta depósitos en:
  - ETH nativo: se swappea automáticamente a USDC mediante el módulo `TokenSwapManager` (Uniswap v4 Universal Router).
  - Tokens ERC20 (incluyendo USDC):
    - Si es USDC, se guarda directamente.
    - Si es otro ERC20, primero se transfiere al contrato y luego se swappea a USDC.
- Mantiene el saldo de cada usuario en un `mapping(address => uint256) balances` expresado en USDC.
- Aplica un límite global de valor depositado (`bankCapUsd`) y un límite por retiro (`withdrawalLimitUsd`), ambos en unidades USDC (6 decimales).
- Usa un módulo de roles (`RoleManager`) basado en `AccessControl` para separar responsabilidades administrativas.

Flujo simplificado:

1. **Depósito de ETH (`depositETH`)**
   - El usuario envía ETH al contrato.
   - El contrato llama a `swapETHForUSDC` (heredado de `TokenSwapManager`), que usa Universal Router para convertir ETH → USDC.
   - Con el resultado en USDC:
     - Se calcula su valor en USD (1:1 con USDC).
     - Se verifica que no se exceda el `bankCapUsd`.
     - Si es válido, se actualiza el saldo del usuario en USDC y `totalUsdDeposited`.
     - Se emite un evento `Deposit`.

2. **Depósito de ERC20 (`depositERC20`)**
   - El usuario aprueba y llama `depositERC20(token, amount)`.
   - Si `token == usdc`:
     - Se transfiere USDC directamente al contrato.
     - `usdcReceived = amount`.
   - Si `token != usdc`:
     - El contrato recibe `token` vía `safeTransferFrom`.
     - Se llama `swapTokenForUSDC(token, amount)` para convertirlo a USDC.
   - Con `usdcReceived`:
     - Se calcula `usdValue = usdcReceived`.
     - Se verifica que `usdValue + totalUsdDeposited <= bankCapUsd`.
     - Si pasa la validación, se incrementa `totalUsdDeposited` y se actualiza `balances[user]`.

3. **Retiro (`withdraw`)**
   - El usuario solicita retirar una cantidad de USDC (`amount`).
   - El contrato verifica:
     - Que el usuario tenga saldo suficiente.
     - Que el retiro no exceda `withdrawalLimitUsd`.
   - Si todo es válido:
     - Resta `amount` del saldo interno del usuario.
     - Disminuye `totalUsdDeposited`.
     - Transfiere `amount` de USDC al usuario.
     - Emite el evento `Withdraw`.

4. **Roles y administración (`RoleManager`)**
   - `DEFAULT_ADMIN_ROLE`: puede asignar y revocar roles, y ejecutar operaciones críticas como `adminRescue`.
   - `CONFIG_ROLE`: destinado a configuraciones futuras (por ejemplo, tokens soportados, parámetros).
   - `PAUSER_ROLE`: pensado para pausar el sistema (aún no implementado completamente en KipuBank V3).

5. **Módulo de swap (`TokenSwapManager`)**
   - Mantiene las direcciones de `usdc` y `universalRouter`.
   - Implementa:
     - `swapTokenForUSDC(token, amount)`: aprueba el Universal Router y ejecuta un swap token → USDC.
     - `swapETHForUSDC(amountIn)`: envía ETH al Universal Router para convertirlo a USDC.
   - Devuelve la cantidad de USDC recibida al contrato que llama (KipuBank).

En síntesis, KipuBank V3 es un vault multi-activo que normaliza todo a USDC, con límites de riesgo en USD y separación de responsabilidades mediante módulos.

---

## 2. Evaluación de la madurez del protocolo

### 2.1 Cobertura de pruebas

- No se observa aún un conjunto de tests específico para KipuBank V3 en `test/` (la estructura actual parece heredada de ejemplos anteriores).
- No hay pruebas unitarias ni de integración que cubran:
  - Swaps con Universal Router (token → USDC, ETH → USDC).
  - Comportamiento de `bankCapUsd` y `withdrawalLimitUsd` con distintos escenarios.
  - Casos límite de balances, depósitos mínimos, y errores personalizados.

**Conclusión:** La cobertura de pruebas es baja. El protocolo aún está en fase de desarrollo/POC y no en fase pre-producción.

### 2.2 Métodos de prueba

- Actualmente no hay evidencia de:
  - Tests de unidad con Foundry para el flujo de depósitos/retiros.
  - Tests de integración contra un fork o mocks del Universal Router.
  - Fuzzing de invariantes (por ejemplo, usando `forge test --fuzz` o herramientas dedicadas).
- Se utilizan errores personalizados, lo cual es bueno para validar condiciones en tests, pero todavía no se aprovecharon en un conjunto de pruebas formal.

### 2.3 Documentación

- Existe `README_BANK3.md` que describe KipuBank V3 a alto nivel (arquitectura, módulos, flujo), lo cual es un buen inicio.
- Falta documentación específica sobre:
  - Parámetros exactos de despliegue (direcciones de `usdc`, Universal Router por red).
  - Riesgos conocidos y limitaciones del módulo de swap.
  - Formato exacto de comandos/inputs esperados por Universal Router (ligado a la versión usada).

### 2.4 Roles y poderes de los actores del protocolo

- **Usuarios finales:**
  - Pueden depositar ETH o tokens ERC20.
  - Pueden retirar USDC hasta su propio balance, limitado por `withdrawalLimitUsd`.

- **Admin (DEFAULT_ADMIN_ROLE):**
  - Puede ejecutar `adminRescue`, rescatando tokens o ETH del contrato.
  - Puede asignar y revocar roles (incluyendo a otros admins, config, pauser).
  - Tiene control significativo sobre el sistema.

- **CONFIG_ROLE y PAUSER_ROLE:**
  - Definidos pero aún poco explotados en KipuBank V3:
    - `CONFIG_ROLE`: futuro encargado de parametrización (tokens, límites, etc.).
    - `PAUSER_ROLE`: futuro encargado de pausar el protocolo ante emergencias.

**Riesgo:**
- Alta concentración de poder en el admin.
- Falta de pausable efectivo en las funciones críticas (`deposit*`, `withdraw`).

### 2.5 Invariantes (visión preliminar)

Algunos invariantes ya se pueden observar (ver sección 4 para más detalle):

- El saldo interno de un usuario no debe ser negativo.
- `totalUsdDeposited` debe ser la suma (aproximada) de todos los balances de usuarios.
- `totalUsdDeposited` ≤ `bankCapUsd`.
- Ningún retiro puede exceder `withdrawalLimitUsd`.

En conjunto, KipuBank V3 avanza hacia un diseño más maduro que V2 (módulos, USDC centralizado, roles), pero aún carece de:

- Suite de tests sólida.
- Módulo pausable activo.
- Auditar el correcto uso del Universal Router y manejo de slippage.

---

## 3. Vectores de ataque y modelo de amenazas

A continuación se identifican al menos 3 superficies de ataque relevantes.

### 3.1 Errores en la lógica de negocio

1. **Manejo incorrecto de balances en USDC**
   - El mapeo `balances[user]` se actualiza en USDC, pero debe garantizarse que siempre refleje el total real que el contrato tiene en USDC.
   - Riesgo: Si se realizan rescates administrativos (`adminRescue`) o swaps fallidos sin ajustar `balances` y `totalUsdDeposited`, podrían quedar saldos "fantasma".

2. **Inconsistencia entre USDC en contrato y totalUsdDeposited**
   - El protocolo asume que todo el valor está en USDC, pero:
     - `adminRescue` permite mover USDC/ETH fuera sin ajustar `totalUsdDeposited`.
     - La lógica no fuerza que el `balanceOf(usdc)` del contrato sea ≥ suma de `balances[user]`.

3. **Ausencia de refunds explícitos en caso de revert de bankCap** (parcialmente mitigado por revert global)
   - `depositERC20` hace:
     - Transferencia
     - Swap
     - Check `bankCapUsd`
     - Si falla, revert → la EVM deshace todo.
   - Aunque funcionalmente esto revierte bien, es fácil introducir cambios futuros que rompan este patrón.

### 3.2 Uso indebido / abuso de supuestos del protocolo

1. **Supuesto 1: 1 USDC ≈ 1 USD siempre válido**
   - El sistema trata USDC como equivalente 1:1 con USD y no vía oráculos.
   - Riesgo:
     - Si USDC pierde su peg o tiene problemas regulatorios, la contabilidad en "USD" deja de representar valor real.

2. **Supuesto 2: Universal Router siempre tiene liquidez adecuada**
   - Se asume que siempre habrá un camino razonable para token → USDC y ETH → USDC.
   - Riesgo:
     - Pools ilíquidos o rutas malas pueden provocar swaps con pésimo precio o slippage extremo.

3. **Supuesto 3: Slippage no importará (minAmountOut = 0)**
   - El código actual usa `minAmountOut = 0`, lo que permite ejecutar swaps con cualquier cantidad mínima, incluso 0.
   - Ataque:
     - Un atacante podría manipular precios o el estado de la pool justo antes del swap (sandwich), obteniendo que el contrato reciba casi 0 USDC a cambio de tokens con valor.

### 3.3 Estrategias económicas / exploitativas

1. **Sandwich / MEV contra los swaps del banco**
   - Cada depósito que llama a `swapTokenForUSDC` o `swapETHForUSDC` es una oportunidad de front-running.
   - Sin slippage bound:
     - El atacante puede reordenar y manipular el precio para que el usuario obtenga pésimo tipo de cambio.

2. **Ataque al bankCap con fluctuaciones de precio**
   - `bankCapUsd` asume USDC estable.
   - Si USDC colapsa / se recupera rápidamente, los límites de cap pierden sentido económico.

3. **Uso de tokens maliciosos**
   - Si el contrato permite swappear tokens arbitrarios sin lista blanca estricta:
     - Un token malicioso podría comportarse de modo inesperado en `transferFrom` o al interactuar con el router.

### 3.4 Problemas de permisos / control de acceso

1. **Poder de `adminRescue`**
   - Permite al admin sacar cualquier cantidad de tokens o ETH del contrato.
   - Sin límites ni multi-sig, un admin comprometido o malintencionado puede drenar el vault.

2. **Roles PAUSER y CONFIG no integrados**
   - Aunque existen en `RoleManager`, no se usan aún para pausar funciones críticas.
   - En un evento de emergencia (bug, exploit del router), no hay mecanismo directo para detener depósitos/retiros.

3. **Falta de restricciones sobre parámetros críticos en constructor**
   - El constructor depende de `_usdc` y `_universalRouter` pasados externamente.
   - Si se despliega con direcciones equivocadas (router falso, token falso), el protocolo queda comprometido desde el inicio.

---

## 4. Especificación de invariantes

A continuación, al menos 3 invariantes claves del protocolo.

### Invariante 1 – No sobrepasar el bankCap

**Descripción:**

- En todo momento:

  \[
  totalUsdDeposited \leq bankCapUsd
  \]

**Intuición:**

- El protocolo se diseña para limitar el valor total depositado, reduciendo la exposición a riesgo.

---

### Invariante 2 – Saldos de usuario no negativos

**Descripción:**

- Para cualquier usuario `u`:

  \[
  balances[u] \geq 0
  \]

**Intuición:**

- Ninguna operación válida debería dejar el saldo interno de un usuario en un valor negativo.
- Los retiros y actualizaciones deben respetar este límite.

---

### Invariante 3 – `totalUsdDeposited` refleja al menos la suma de balances

**Descripción (simplificada):**

- Idealmente:

  \[
  totalUsdDeposited = \sum_{u} balances[u]
  \]

- Dado que no se guarda un listado explícito de usuarios, en la práctica la condición fuerte a verificar es:

  - Para cualquier operación:
    - Los incrementos/decrementos de `totalUsdDeposited` deben ser coherentes con los cambios en `balances[user]`.

**Intuición:**

- `totalUsdDeposited` debe ser la vista global del sistema, consistente con los saldos individuales.

---

### Invariante 4 – Límite por retiro

**Descripción:**

- Para cualquier llamada a `withdraw(amount)` exitosa:

  \[
  amount \leq withdrawalLimitUsd
  \]

**Intuición:**

- El protocolo debe impedir retiros individuales demasiado grandes.

---

## 5. Impacto de las violaciones de invariantes

### Violación del Invariante 1 – Sobrepasar `bankCapUsd`

**Impacto:**

- El vault almacenaría más valor del previsto por el diseño de riesgo.
- Cualquier exploit que permita saltarse esta verificación implica exposición mayor y potencial pérdida masiva en caso de fallo.

### Violación del Invariante 2 – Saldos negativos

**Impacto:**

- Estados imposibles: lógica contable rota.
- Podrían aparecer usuarios con saldo negativo que no corresponde con ninguna operación real.
- Facilita errores adicionales, p. ej. "perdonar" deuda sin intención.

### Violación del Invariante 3 – Divergencia `totalUsdDeposited` / balances

**Impacto:**

- El valor global que cree ver el protocolo puede no coincidir con el valor real retenido.
- Podría:
  - Permitir que algunos usuarios retiren más de lo que el contrato tiene realmente.
  - Inducir decisiones administrativas erróneas (por ejemplo, creer que hay menos valor bajo custodia del que hay en realidad).

### Violación del Invariante 4 – Retiros mayores a `withdrawalLimitUsd`

**Impacto:**

- Un usuario podría realizar retiros muy grandes en una sola operación.
- Empeora el perfil de riesgo y favorece retiros masivos inesperados (bank run más violento).

---

## 6. Recomendaciones para validar los invariantes

### 6.1 Pruebas unitarias y de integración

- Implementar tests con Foundry centrados en invariantes:
  - `totalUsdDeposited` nunca debe exceder `bankCapUsd`.
  - Después de cada depósito/retiro, verificar que `balances[user]` es coherente con `totalUsdDeposited`.
  - Asegurar que todos los errores personalizados (`BankCapExceeded`, `WithdrawalLimitExceeded`, etc.) se disparan en las condiciones adecuadas.

- Tests de integración con mocks del Universal Router o un fork:
  - Verificar swaps normales con liquidez suficiente.
  - Simular fallos del router (reverts) y comprobar que no se corrompe el estado.

### 6.2 Fuzzing e invariantes automatizados

- Usar herramientas de fuzzing (p. ej. `forge test --fuzz` o frameworks de invariants) para:
  - Ejecutar secuencias aleatorias de `depositETH`, `depositERC20`, `withdraw`.
  - Verificar en cada paso que las invariantes se mantienen.

### 6.3 Checks adicionales en código

- Añadir validaciones explícitas en puntos críticos:
  - Antes y después de `adminRescue`, comparar `IERC20(usdc).balanceOf(address(this))` con alguna métrica de referencia.
  - Limitar `adminRescue` para no retirar USDC por encima de un margen tolerado vs. `totalUsdDeposited`.

### 6.4 Slippage y precios

- Reemplazar `minAmountOut = 0` por un cálculo basado en:
  - Precios de referencia (Chainlink u otra fuente) o
  - Estimaciones de cotización del router.
- Parametrizar `slippageBps` y probar diferentes valores en testnet.

---

## 7. Conclusión y próximos pasos

### Estado actual de madurez

- KipuBank V3 representa un salto cualitativo respecto a V2:
  - Contabilidad unificada en USDC.
  - Módulo de swaps separado.
  - Gestión de roles modular y extensible.
- Sin embargo, aún se encuentra en una fase de **preparación para auditoría**, no de producción:
  - Falta una suite de pruebas robusta.
  - El manejo de slippage y precios en los swaps es mínimo.
  - Los roles de pausa y configuración no están completamente integrados.

### Próximos pasos recomendados

1. **Fortalecer pruebas**
   - Añadir pruebas unitarias de cada flujo (depósito, retiro, rescue, swaps).
   - Incluir pruebas de error (reverts) y de invariantes.

2. **Integrar pausable y circuit breaker**
   - Implementar funciones `pause`/`unpause` controladas por `PAUSER_ROLE`.
   - Restringir `deposit*` y `withdraw` cuando el sistema esté en pausa.

3. **Mejorar el módulo de swaps**
   - Parametrizar correctamente `minAmountOut`.
   - Verificar la compatibilidad exacta con la versión particular de Universal Router.
   - Añadir lista blanca de tokens soportados para evitar tokens maliciosos.

4. **Revisar gobernanza y administración**
   - Migrar `DEFAULT_ADMIN_ROLE` a una multi-sig o contrato de gobernanza.
   - Documentar claramente los poderes del admin y sus límites.

5. **Preparar documentación para auditoría**
   - Especificación funcional detallada de cada función pública.
   - Diagrama de arquitectura (módulos, interacciones con router, roles).
   - Lista de invariantes y amenazas conocidas (este documento como base).

---

## Consideraciones finales

Este análisis de amenazas simula el trabajo real que debe hacer un desarrollador de Solidity antes de exponer un protocolo a usuarios:

- Entender a fondo el modelo de negocio y los flujos de valor.
- Identificar invariantes y propiedades críticas del sistema.
- Pensar como atacante: buscar supuestos débiles, vectores de MEV, errores de permisos.
- Traducir esas observaciones en pruebas, documentación y planes de mitigación.

Completar este ejercicio demuestra que no solo puedes escribir contratos inteligentes, sino también:

- Evaluar riesgos técnicos y económicos.
- Diseñar lógica defensiva.
- Comunicar hallazgos de manera clara.
- Contribuir a un ecosistema Web3 más seguro.

La diferencia entre un despliegue amateur y un protocolo profesional está en este tipo de trabajo previo: análisis, pruebas, revisión de amenazas y especificación de invariantes. KipuBank V3 es un buen punto de partida; los pasos descritos aquí marcan el camino para llevarlo a un nivel de madurez apto para una auditoría formal y, eventualmente, para producción.