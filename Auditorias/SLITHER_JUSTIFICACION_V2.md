# Informe de Análisis Estático con Slither y Justificación Técnica de Hallazgos (TP v2)

## 1. Comando Ejecutado y Alcance del Análisis

```bash
cd /workspace/TP_v2 && slither . --filter-paths "lib/|test/|script/|Auditorias/|src/" 2>&1 | tee logs/slither.txt
```

### Justificación Metodológica de `--filter-paths` (Exclusión de Librerías de Terceros y Entornos de Prueba)

Siguiendo las mejores prácticas de ingeniería de seguridad Web3 (Trail of Bits / Cyfrin / OpenZeppelin), en la ejecución de Slither se aplicó la bandera `--filter-paths "lib/|test/|script/|Auditorias/|src/"` por tres razones técnicas fundamentales:

1. **Exclusión de `@openzeppelin/contracts` v5.1.0 y `forge-std` (`lib/`):**
   - Los contratos base de OpenZeppelin v5 (`ERC721`, `ERC721Votes`, `Governor`, `GovernorTimelockControl`, `TimelockController`, `Ownable2Step`, `ReentrancyGuard`, `Pausable`) son librerías estándar de la industria ya auditadas formalmente por múltiples firmas internacionales (OpenZeppelin Security, Trail of Bits, Certora).
   - Dichas librerías emplean de manera intencional bloques de bajo nivel (`assembly` optimizado en memoria, `low-level calls` para ejecución de propuestas en `TimelockController`, y aritmética `unchecked` tras validaciones previas) que disparan decenas de alertas informativas en analizadores estáticos sin representar vulnerabilidades reales.
   - Filtrar `lib/` evita la contaminación de ruido (*alert fatigue*) y garantiza que el análisis de los **102 detectores de Slither** se concentre **100% en la superficie de ataque real escrita por el desarrollador** en `contracts/` (`ConsorcioVotes.sol`, `ConsorcioTimelock.sol`, `ConsorcioGovernor.sol` y `ConsorcioObras.sol`).
2. **Exclusión de `test/`, `Auditorias/` y `script/`:**
   - Los contratos de prueba (`ConsorcioDAO.t.sol`, `ConsorcioDAOInvariants.t.sol`, `ConsorcioDAOEchidna.sol`) incluyen deliberadamente contratos simuladores de ataque o rechazo de fondos (`ContratistaRechazaETH`) y llamadas `vm.prank` que no forman parte del bytecode desplegado en producción en Ethereum Sepolia.
3. **Exclusión del boilerplate `src/`:**
   - Excluye la plantilla por defecto de Foundry (`Counter.sol`), concentrando las métricas exclusivamente en la arquitectura `contracts/`.

---

## 2. Salida Literal de Consola (`logs/slither.txt`)

```text
'forge clean' running (wd: /workspace/TP_v2)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: /workspace/TP_v2)
INFO:Detectors:
Detector: missing-zero-check
ConsorcioVotes.constructor(address).initialOwner (contracts/ConsorcioVotes.sol#124) lacks a zero-check on :
                - registrador = initialOwner (contracts/ConsorcioVotes.sol#130)
ConsorcioVotes.actualizarRegistrador(address).nuevoRegistrador (contracts/ConsorcioVotes.sol#143) lacks a zero-check on :
                - registrador = nuevoRegistrador (contracts/ConsorcioVotes.sol#145)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-zero-address-validation
INFO:Detectors:
Detector: reentrancy-benign
Reentrancy in ConsorcioObras._transferirETH(address,uint256) (contracts/ConsorcioObras.sol#765-773):
        External calls:
        - (exito,None) = destinatario.call{value: monto}() (contracts/ConsorcioObras.sol#766)
        State variables written after the call(s):
        - pagosPendientesContratista[destinatario] = nuevoPendiente (contracts/ConsorcioObras.sol#769)
        - totalPagosPendientesContratistas += monto (contracts/ConsorcioObras.sol#770)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3
INFO:Detectors:
Detector: dead-code
ConsorcioVotes._increaseBalance(address,uint128) (contracts/ConsorcioVotes.sol#281-283) is never used and should be removed
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#dead-code
INFO:Detectors:
Detector: low-level-calls
Low level call in ConsorcioObras.retirarPagoContratista(address) (contracts/ConsorcioObras.sol#601-621):
        - (exito,None) = receptor.call{value: monto}() (contracts/ConsorcioObras.sol#619)
Low level call in ConsorcioObras._transferirETH(address,uint256) (contracts/ConsorcioObras.sol#765-773):
        - (exito,None) = destinatario.call{value: monto}() (contracts/ConsorcioObras.sol#766)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#low-level-calls
INFO:Detectors:
Detector: missing-inheritance
ConsorcioVotes (contracts/ConsorcioVotes.sol#30-284) should inherit from IConsorcioVotes (contracts/ConsorcioObras.sol#12-14)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-inheritance
INFO:Detectors:
Detector: naming-convention
Function ConsorcioVotes.CLOCK_MODE() (contracts/ConsorcioVotes.sol#251-253) is not in mixedCase
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#conformance-to-solidity-naming-conventions
INFO:Slither:. analyzed (57 contracts with 102 detectors), 8 result(s) found
```

---

## 3. Resumen de Severidades

| Severidad | Cantidad | Estado |
| :--- | :---: | :--- |
| **Crítica (Critical)** | **0** | ✅ Aprobado |
| **Alta (High)** | **0** | ✅ Aprobado |
| **Media (Medium)** | **0** | ✅ Aprobado |
| **Baja / Benigna / Informativa** | **8** (agrupados en 6 detectores) | ✅ Analizados y Justificados |

---

## 4. Tabla de Justificación Técnica Hallazgo por Hallazgo (Aceptación / Falso Positivo)

| # | Detector de Slither | Ubicación Exacta | Clasificación | Decisión | Justificación Técnica y de Negocio |
| :-: | :--- | :--- | :---: | :---: | :--- |
| **1** | `missing-zero-check` (1/2) | `ConsorcioVotes.constructor(address initialOwner)` (`contracts/ConsorcioVotes.sol#124-130`) | **Falso Positivo** (Validado por herencia OZ v5) | **No requiere cambio (Mitigado)** | El constructor invoca primero `Ownable(initialOwner)` de OpenZeppelin v5, el cual revierte automáticamente con `OwnableInvalidOwner(address(0))` si `initialOwner == address(0)`. Por lo tanto, es matemáticamente imposible que `registrador = initialOwner` reciba la dirección cero en el despliegue. |
| **2** | `missing-zero-check` (2/2) | `ConsorcioVotes.actualizarRegistrador(address nuevoRegistrador)` (`contracts/ConsorcioVotes.sol#143-145`) | **Decisión de Diseño Buscada** (**Corrección Docente #6**) | **Se acepta por diseño** | En la **Corrección Docente #6** (doble vía `onlyRegistradorOrOwner`), permitir que `onlyOwner` (el `ConsorcioTimelock`) asigne `registrador = address(0)` es una **funcionalidad deliberada de seguridad**: permite revocar o desactivar por completo la vía rápida del registrador administrativo si la asamblea de vecinos decide que las altas y reasignaciones de unidades queden exclusivamente bajo control directo del `Timelock`. |
| **3** | `reentrancy-benign` | `ConsorcioObras._transferirETH(address, uint256)` (`contracts/ConsorcioObras.sol#765-773`) | **Benigno / Diseño Híbrido Push + Pull** (**Corrección Docente #2**) | **Se acepta por diseño (Protegido)** | En la **Corrección Docente #2**, implementamos el patrón híbrido *Push + Pull Fallback*: primero se actualiza todo el estado de la obra (`totalLiberado`, `hitoPagado`, `fondosComprometidos`) siguiendo estrictamente **Checks-Effects-Interactions (CEI)** antes de llamar a `_transferirETH`. Además, todas las funciones públicas que invocan `_transferirETH` están protegidas con el modificador `nonReentrant` de OpenZeppelin (`ReentrancyGuard`). Las variables `pagosPendientesContratista` y `totalPagosPendientesContratistas` solo se escriben en la rama `if (!exito)` (cuando la llamada externa falló y no transfirió ETH), acreditando el saldo en custodia sin revertir la propuesta del Timelock. |
| **4** | `dead-code` | `ConsorcioVotes._increaseBalance(address, uint128)` (`contracts/ConsorcioVotes.sol#281-283`) | **Falso Positivo de Compilación** (Override obligatorio de Solidity) | **Se acepta (Requerido por `solc 0.8.24`)** | En OpenZeppelin v5, tanto `ERC721` como `ERC721Votes` definen la función virtual interna `_increaseBalance(address, uint128)`. El compilador `solc 0.8.24` exige obligatoriamente sobrescribirla con `override(ERC721, ERC721Votes)` para resolver la herencia múltiple en diamante, aunque el contrato use `_safeMint` unitario. Eliminarla impediría compilar el contrato. |
| **5** | `low-level-calls` (1/2) | `ConsorcioObras.retirarPagoContratista(address)` (`contracts/ConsorcioObras.sol#619`) | **Buena Práctica Web3** | **Se acepta (Estándar de Seguridad)** | Desde la actualización Estambul (EIP-1884), el uso de `.transfer()` y `.send()` está desaconsejado porque su estipendio fijo de `2300 gas` rompe la compatibilidad con billeteras multisig (Safe) o proxies. El uso de `receptor.call{value: monto}("")` combinado con `nonReentrant` y actualización previa de estado a cero (`pagosPendientesContratista[msg.sender] = 0`) es el estándar de seguridad recomendado en Solidity `^0.8.24`. |
| **6** | `low-level-calls` (2/2) | `ConsorcioObras._transferirETH(address, uint256)` (`contracts/ConsorcioObras.sol#766`) | **Buena Práctica Web3** (**Corrección Docente #2**) | **Se acepta (Estándar de Seguridad)** | Ídem anterior: `destinatario.call{value: monto}("")` permite enviar fondos al contratista en el camino *Push* e inspeccionar el booleano `exito` sin propagar un `revert` automático, habilitando el camino *Pull Fallback* (`pagosPendientesContratista`) solicitado por el docente. |
| **7** | `missing-inheritance` | `ConsorcioVotes` respecto de `IConsorcioVotes` (`contracts/ConsorcioObras.sol#12-14`) | **Informativo / Desacoplamiento Arquitectónico** | **Se acepta por diseño** | `IConsorcioVotes` es una interfaz mínima de lectura (`function propietarioDeUnidad(uint256 unidadId) external view returns (address)`) declarada localmente en `ConsorcioObras.sol` (**Corrección Docente #3**) para mantener los contratos desacoplados y evitar dependencias circulares de importación. La firma ABI de `ConsorcioVotes.propietarioDeUnidad(uint256)` coincide exactamente al 100%. |
| **8** | `naming-convention` | `ConsorcioVotes.CLOCK_MODE()` (`contracts/ConsorcioVotes.sol#251-253`) | **Falso Positivo** (Estándar EIP-6372) | **Se acepta (Requisito ERC-6372 / OZ Governor)** | El estándar **EIP-6372 (Contract Clock)** y la interfaz `IERC6372` de OpenZeppelin v5 exigen que la función pública se llame exactamente `CLOCK_MODE()` en mayúsculas. Cambiarla a `mixedCase` rompería la compatibilidad con `ConsorcioGovernor`. |
