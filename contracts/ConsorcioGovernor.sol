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
 *      - `GovernorVotesQuorumFraction`: Define el quórum como porcentaje de unidades totales (ej. 4% a 100%).
 *      - `GovernorTimelockControl`: Encola y ejecuta todas las decisiones aprobadas a través de `ConsorcioTimelock`.
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
    // Constantes y Errores Personalizados (Custom Errors)
    // =========================================================================

    /// @notice Porcentaje mínimo de quórum permitido por seguridad estatutaria (4%).
    uint256 public constant QUORUM_MINIMO = 4;

    /// @notice Porcentaje máximo de quórum permitido (100%).
    uint256 public constant QUORUM_MAXIMO = 100;

    /// @notice Se lanza cuando el período de votación inicial es cero (`_votingPeriod == 0`).
    error PeriodoVotacionInvalido();

    /// @notice Se lanza cuando el porcentaje de quórum está fuera del rango seguro `[4, 100]`.
    /// @param quorumRecibido Valor de porcentaje de quórum inválido provisto en el constructor.
    error QuorumInvalido(uint256 quorumRecibido);

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
     * @param _quorumPercentage Porcentaje de quórum requerido sobre el total de unidades (`4 <= q <= 100`).
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
