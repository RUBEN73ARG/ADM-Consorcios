// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernor, Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title ConsorcioGovernor
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Contrato de Gobernanza de la comunidad (Consorcio de edificio o Country).
 * @dev Generado y estructurado siguiendo el estándar de OpenZeppelin Contracts Wizard v5:
 *      https://wizard.openzeppelin.com/#governor
 *      y las plantillas de referencia:
 *      - https://github.com/PatrickAlphaC/dao-template
 *      - https://github.com/Cyfrin/foundry-dao-cu
 *
 *      Módulos integrados:
 *      - `GovernorSettings`: Configura período de deliberación previo (`votingDelay`),
 *        duración de la votación (`votingPeriod`) y umbral mínimo para proponer (`proposalThreshold`).
 *      - `GovernorCountingSimple`: Votación estándar (0 = En Contra, 1 = A Favor, 2 = Abstención).
 *      - `GovernorVotes`: Extrae el peso de voto desde `ConsorcioVotes` (`ERC721Votes`) según el snapshot histórico.
 *      - `GovernorVotesQuorumFraction`: Define el quórum como porcentaje de unidades totales (`30%` a `100%`).
 *      - `GovernorTimelockControl`: Encola y ejecuta todas las decisiones aprobadas a través de `ConsorcioTimelock`.
 *
 *      =========================================================================
 *      CORRECCIONES DE MENTORÍA DOCENTE IMPLEMENTADAS EN ESTE CONTRATO:
 *      =========================================================================
 *      1. [CORRECCIÓN DOCENTE - PUNTO 1] (Quórum estatutario mínimo del 30% al 50%):
 *         - Observación: Con `GovernorVotesQuorumFraction` al 4% y pocas unidades funcionales (`< 25`),
 *           la división entera `(totalSupply * 4) / 100` trunca a `0`, permitiendo aprobar propuestas con 1 solo voto.
 *         - Solución implementada: Se eleva `QUORUM_MINIMO` a `30` (30%) y se despliega el consorcio con un
 *           quórum estatutario del `50%` (rango recomendado 30%–50% acorde al régimen de asambleas del CCyC).
 *           Con `quorumDenominator() == 100` constante en OpenZeppelin, jamás existe división por cero, y para
 *           todo consorcio constituido (`totalSupply >= 4` unidades) el quórum exige al menos 2 unidades
 *           (`(4 * 50) / 100 = 2`), verificado formalmente con pruebas de invariantes en Foundry y Echidna.
 *         - Nota de arquitectura (Alternativa teórica no requerida en código): Otra variante posible en sistemas
 *           con `quorumNumerator` muy bajo (<10%) consiste en sobreescribir `quorum(uint256 timepoint)` aplicando
 *           redondeo hacia arriba `(supply * num + 99) / 100` o un piso fijo `max(super.quorum(t), MIN_VOTES)`.
 *           Al fijar `QUORUM_MINIMO = 30` y operar al `50%`, el cálculo nativo de OpenZeppelin resuelve el problema
 *           sin alterar la fórmula estándar auditada.
 *
 *      2. [CORRECCIÓN DOCENTE - PUNTO 5] (Cancelación de propuestas en estado `Queued` durante `minDelay`):
 *         - Observación: `ConsorcioGovernor` recibe `CANCELLER_ROLE` en `ConsorcioTimelock`, pero en OpenZeppelin v5
 *           la función pública `cancel()` solo permite al proponente cancelar mientras la propuesta está en `Pending`.
 *           Una vez aprobada y encolada (`Queued`), no existía una función expuesta para cancelarla durante la
 *           ventana de seguridad (`minDelay`) del Timelock.
 *         - Solución implementada: Se incorpora el rol `guardian` (Síndico / Auditor de seguridad, actualizable
 *           por gobernanza) y la función externa `cancelarPropuestaEnCola(...)`, que permite al `guardian` o al
 *           proponente original cancelar una propuesta en estado `Queued` invocando `_cancel(...)`, lo cual revoca
 *           la operación tanto en el Governor como en `ConsorcioTimelock` antes de que venza el `minDelay`.
 */
contract ConsorcioGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // =========================================================================
    // Constantes, Variables de Estado y Errores Personalizados (Custom Errors)
    // =========================================================================

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 1] Porcentaje mínimo de quórum permitido por seguridad estatutaria (30%).
    /// @dev Evita que en consorcios de pocas unidades la división entera `(totalSupply * pct) / 100` resulte en 0.
    uint256 public constant QUORUM_MINIMO = 30;

    /// @notice Porcentaje máximo de quórum permitido (100%).
    uint256 public constant QUORUM_MAXIMO = 100;

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Dirección del Guardián / Síndico facultado para cancelar
    ///         propuestas encoladas (`Queued`) durante la ventana de seguridad (`minDelay`) del Timelock.
    address public guardian;

    /// @notice Se lanza cuando el período de votación inicial es cero (`_votingPeriod == 0`).
    error PeriodoVotacionInvalido();

    /// @notice Se lanza cuando el porcentaje de quórum está fuera del rango seguro `[30, 100]`.
    /// @param quorumRecibido Valor de porcentaje de quórum inválido provisto en el constructor.
    error QuorumInvalido(uint256 quorumRecibido);

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Se lanza cuando se proporciona `address(0)` como nuevo guardián.
    error DireccionGuardianInvalida();

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Se lanza cuando una cuenta sin permisos intenta cancelar una propuesta en cola.
    /// @param llamador Dirección que intentó cancelar la propuesta.
    /// @param proponente Dirección del autor original de la propuesta.
    /// @param guardianActual Dirección actual del guardián del consorcio.
    error NoAutorizadoParaCancelar(address llamador, address proponente, address guardianActual);

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Se lanza cuando se intenta usar `cancelarPropuestaEnCola` sobre una propuesta que no está en estado `Queued`.
    /// @param proposalId Identificador de la propuesta.
    /// @param estadoActual Estado actual de la propuesta en el Governor.
    error PropuestaNoEncolada(uint256 proposalId, ProposalState estadoActual);

    // =========================================================================
    // Eventos
    // =========================================================================

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Se emite cuando la gobernanza actualiza la dirección del Guardián.
    /// @param guardianAnterior Dirección previa del guardián.
    /// @param nuevoGuardian Nueva dirección asignada como guardián.
    event GuardianActualizado(address indexed guardianAnterior, address indexed nuevoGuardian);

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 5] Se emite cuando una propuesta en estado `Queued` es cancelada durante el `minDelay`.
    /// @param proposalId Identificador de la propuesta cancelada.
    /// @param ejecutadaPor Dirección (Guardián o Proponente) que ejecutó la cancelación de emergencia.
    event PropuestaEnColaCancelada(uint256 indexed proposalId, address indexed ejecutadaPor);

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Inicializa el motor de gobernanza vinculándolo al NFT de unidades (`ConsorcioVotes`) y al Timelock.
     * @param _token Contrato `ConsorcioVotes` (implementa `IVotes` con reloj en modo timestamp).
     * @param _timelock Contrato `ConsorcioTimelock` que custodia y ejecuta las órdenes sobre `ConsorcioObras`.
     * @param _votingDelay Período de deliberación antes de abrir la votación (ej. 86400 = 1 día).
     * @param _votingPeriod Duración de la ventana de votación (ej. 432000 = 5 días; debe ser > 0).
     * @param _proposalThreshold Mínimo de unidades requeridas para crear una propuesta (ej. 0 o 1 unidad).
     * @param _quorumPercentage Porcentaje de quórum requerido sobre el total de unidades (`30 <= q <= 100`).
     */
    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumPercentage
    )
        Governor("ConsorcioGovernor")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {
        if (_votingPeriod == 0) revert PeriodoVotacionInvalido();
        if (_quorumPercentage < QUORUM_MINIMO || _quorumPercentage > QUORUM_MAXIMO) {
            revert QuorumInvalido(_quorumPercentage);
        }

        // [CORRECCIÓN DOCENTE - PUNTO 5] Inicializa al deployer/Síndico como Guardián inicial de emergencia
        guardian = msg.sender;
        emit GuardianActualizado(address(0), msg.sender);
    }

    // =========================================================================
    // [CORRECCIÓN DOCENTE - PUNTO 5] Cancelación en Ventana de Seguridad (Queued)
    // =========================================================================

    /**
     * @notice Cancela una propuesta que ya fue aprobada y encolada (`Queued`) durante el período de espera (`minDelay`) del Timelock.
     * @dev [CORRECCIÓN DOCENTE - PUNTO 5] Materializa la ventana de seguridad del Timelock: si tras aprobarse
     *      una propuesta se detecta un error en el presupuesto, un problema con el contratista o una emergencia
     *      edilicia antes de que venza el `minDelay`, el `guardian` (Síndico) o el `proposalProposer` original
     *      pueden cancelar la operación encolada. Internamente invoca `_cancel(...)`, que marca la propuesta como
     *      `Canceled` en `ConsorcioGovernor` y ejecuta `_timelock.cancel(timelockId)` usando el `CANCELLER_ROLE`.
     * @param targets Lista de contratos destino de la propuesta encolada.
     * @param values Lista de montos en wei de la propuesta encolada.
     * @param calldatas Lista de payloads codificados de la propuesta encolada.
     * @param descriptionHash Hash `keccak256` de la descripción original de la propuesta.
     * @return proposalId Identificador de la propuesta cancelada.
     */
    function cancelarPropuestaEnCola(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId) {
        proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        ProposalState estadoActual = state(proposalId);
        if (estadoActual != ProposalState.Queued) {
            revert PropuestaNoEncolada(proposalId, estadoActual);
        }

        address proponente = proposalProposer(proposalId);
        address guardianActual = guardian;
        if (msg.sender != guardianActual && msg.sender != proponente) {
            revert NoAutorizadoParaCancelar(msg.sender, proponente, guardianActual);
        }

        _cancel(targets, values, calldatas, descriptionHash);

        emit PropuestaEnColaCancelada(proposalId, msg.sender);
    }

    /**
     * @notice Permite a la gobernanza (vía Timelock) rotar o actualizar la dirección del Guardián.
     * @dev [CORRECCIÓN DOCENTE - PUNTO 5] Garantiza que el rol de Guardián esté subordinado a la asamblea.
     * @param nuevoGuardian Nueva dirección autorizada para cancelar propuestas en cola durante emergencias.
     */
    function actualizarGuardian(address nuevoGuardian) external onlyGovernance {
        if (nuevoGuardian == address(0)) revert DireccionGuardianInvalida();
        address anterior = guardian;
        guardian = nuevoGuardian;
        emit GuardianActualizado(anterior, nuevoGuardian);
    }

    /**
     * @notice Sobreescribe la validación de actualización de porcentaje de quórum para exigir siempre `>= QUORUM_MINIMO` (30%).
     * @dev [CORRECCIÓN DOCENTE - PUNTO 1] Impide que una propuesta futura reduzca el numerador de quórum por debajo del 30%.
     * @param newQuorumNumerator Nuevo porcentaje de quórum propuesto (`30 <= newQuorumNumerator <= 100`).
     */
    function _updateQuorumNumerator(uint256 newQuorumNumerator) internal override {
        if (newQuorumNumerator < QUORUM_MINIMO || newQuorumNumerator > QUORUM_MAXIMO) {
            revert QuorumInvalido(newQuorumNumerator);
        }
        super._updateQuorumNumerator(newQuorumNumerator);
    }

    // =========================================================================
    // Overrides requeridos por la herencia múltiple de OpenZeppelin v5
    // =========================================================================

    /// @inheritdoc IGovernor
    function votingDelay()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    /// @inheritdoc IGovernor
    function votingPeriod()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    /// @inheritdoc IGovernor
    function quorum(uint256 timepoint)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(timepoint);
    }

    /// @inheritdoc IGovernor
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @inheritdoc IGovernor
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @inheritdoc Governor
    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /// @inheritdoc Governor
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
