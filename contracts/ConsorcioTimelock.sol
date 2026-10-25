// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title ConsorcioTimelock
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Bóveda de retardo temporal (TimelockController) que protege las decisiones del Consorcio.
 * @dev Basado en TimelockController de OpenZeppelin v5:
 *      https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/governance/TimelockController.sol
 *
 *      Garantiza que ninguna liberación de fondos para obras se ejecute por sorpresa:
 *      toda propuesta aprobada por `ConsorcioGovernor` debe permanecer en cola durante
 *      al menos `minDelay` (ej. 24 a 48 horas = 86400 a 172800 segundos) antes de poder
 *      ejecutarse sobre `ConsorcioObras`.
 *
 *      Incluye la función de sellado atómico `configurarYSellarGobernanza(address governor)`
 *      para mitigar el riesgo de centralización post-despliegue: en una sola transacción
 *      asigna los roles al `ConsorcioGovernor` y revoca el `DEFAULT_ADMIN_ROLE` del deployer.
 *
 *      [CORRECCIÓN DOCENTE - PUNTO 5] (Ventana de seguridad durante `minDelay`):
 *      Al otorgar `CANCELLER_ROLE` al contrato `ConsorcioGovernor`, este puede invocar
 *      `_timelock.cancel(id)` a través de `ConsorcioGovernor.cancelarPropuestaEnCola(...)`
 *      mientras una propuesta aprobada se encuentra en estado `Queued` esperando que transcurra
 *      el `minDelay`, materializando una ventana real de veto/emergencia antes de su ejecución.
 *
 *      Roles relevantes heredados de `TimelockController` (AccessControl):
 *      - `PROPOSER_ROLE`: Exclusivo para `ConsorcioGovernor` (encola propuestas votadas).
 *      - `CANCELLER_ROLE`: Otorgado a `ConsorcioGovernor` para cancelar operaciones en cola (`Queued`).
 *      - `EXECUTOR_ROLE`: Configurado en `address(0)` (y `ConsorcioGovernor`) para ejecución abierta tras `minDelay`.
 *      - `DEFAULT_ADMIN_ROLE`: Usado solo durante el despliegue y sellado atómicamente para autonomía total.
 */
contract ConsorcioTimelock is TimelockController {
    // =========================================================================
    // Variables de Estado
    // =========================================================================

    /// @notice Indica si la gobernanza ya fue configurada y el rol de administrador inicial fue revocado.
    bool public gobernanzaSellada;

    // =========================================================================
    // Errores Personalizados (Custom Errors)
    // =========================================================================

    /// @notice Se lanza cuando se proporciona `address(0)` como dirección del contrato Governor.
    error DireccionGovernorInvalida();

    /// @notice Se lanza cuando se intenta volver a ejecutar el sellado atómico de gobernanza.
    error GobernanzaYaSellada();

    // =========================================================================
    // Eventos
    // =========================================================================

    /// @notice Se emite cuando se asignan los roles al Governor y el deployer renuncia a `DEFAULT_ADMIN_ROLE`.
    /// @param governor Dirección del contrato `ConsorcioGovernor` autorizado.
    /// @param adminSaliente Dirección del administrador de despliegue que renunció a sus privilegios.
    event GobernanzaConfiguradaYSellada(address indexed governor, address indexed adminSaliente);

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Inicializa el controlador de retardo temporal del consorcio.
     * @param minDelay Tiempo mínimo de espera en segundos (ej. 172800 para 48 horas) entre
     *                 el encolado (`queue`) de una propuesta aprobada y su ejecución (`execute`).
     * @param proposers Lista de direcciones autorizadas a encolar propuestas (el `ConsorcioGovernor`).
     * @param executors Lista de direcciones autorizadas a ejecutar propuestas vencido el plazo
     *                  (usar `address(0)` permite que cualquier miembro de la comunidad ejecute).
     * @param admin Dirección administradora temporal para configurar el rol del Governor tras el deploy.
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}

    // =========================================================================
    // Funciones Externas de Configuración y Sellado Atómico
    // =========================================================================

    /**
     * @notice Configura los roles del `ConsorcioGovernor` y revoca atómicamente el `DEFAULT_ADMIN_ROLE` del deployer.
     * @dev Elimina la vulnerabilidad de retención de `DEFAULT_ADMIN_ROLE` post-despliegue: en una única
     *      transacción otorga `PROPOSER_ROLE`, `CANCELLER_ROLE` y `EXECUTOR_ROLE` al Governor, habilita la
     *      ejecución pública (`address(0)`) y ejecuta `renounceRole(DEFAULT_ADMIN_ROLE, msg.sender)`.
     * @param governor Dirección del contrato `ConsorcioGovernor` recién desplegado.
     */
    function configurarYSellarGobernanza(address governor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governor == address(0)) revert DireccionGovernorInvalida();
        if (gobernanzaSellada) revert GobernanzaYaSellada();

        gobernanzaSellada = true;

        _grantRole(PROPOSER_ROLE, governor);
        _grantRole(CANCELLER_ROLE, governor);
        _grantRole(EXECUTOR_ROLE, governor);
        _grantRole(EXECUTOR_ROLE, address(0));

        // El deployer renuncia de forma irrevocable a la administración manual del Timelock
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit GobernanzaConfiguradaYSellada(governor, msg.sender);
    }
}
