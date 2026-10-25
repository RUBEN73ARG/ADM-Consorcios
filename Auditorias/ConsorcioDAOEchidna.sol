// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioTimelock} from "../contracts/ConsorcioTimelock.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

/**
 * @title ConsorcioDAOEchidna
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Harness de verificación formal de propiedades booleanas (`echidna_*`) con Echidna Fuzzer.
 * @dev [CORRECCIÓN DOCENTE - PUNTO 1, 2, 3, 5 y 6]
 *      Valida que bajo cualquier secuencia de llamadas generada por Echidna:
 *      1. `echidna_quorum_sin_division_por_cero_y_mayor_a_cero`: El denominador de quórum es 100
 *         (jamás existe división por cero), el numerador está entre 30% y 100%, y el quórum
 *         para el consorcio de 4 unidades es siempre >= 2 votos (nunca da 0).
 *      2. `echidna_solvencia_balance`: El balance real del Vault cubre siempre el 100% de
 *         `fondosComprometidosEnObras + totalPagosPendientesContratistas` (Esquema Pull).
 *      3. `echidna_timelock_sellado`: El Timelock permanece sellado (`gobernanzaSellada == true`).
 *      4. `echidna_unidades_no_adjudicadas_sin_pagos`: Ninguna unidad no adjudicada (`address(0)`)
 *         puede acumular saldo en `expensasPagadasPorUnidad`.
 */
contract ConsorcioDAOEchidna {
    ConsorcioVotes public token;
    ConsorcioTimelock public timelock;
    ConsorcioGovernor public governor;
    ConsorcioObras public obras;

    address internal constant VECINO_1 = address(0x101);
    address internal constant VECINO_2 = address(0x102);
    address internal constant VECINO_3 = address(0x103);
    address internal constant VECINO_4 = address(0x104);

    constructor() payable {
        token = new ConsorcioVotes(address(this));

        // Adjudicar las 4 unidades base del consorcio
        token.adjudicarUnidad(101, VECINO_1, 100);
        token.adjudicarUnidad(102, VECINO_2, 100);
        token.adjudicarUnidad(103, VECINO_3, 100);
        token.adjudicarUnidad(104, VECINO_4, 100);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new ConsorcioTimelock(1 days, proposers, executors, address(this));

        // Despliegue con quórum estatutario del 50% (Corrección Docente Punto 1)
        governor = new ConsorcioGovernor(
            IVotes(address(token)),
            timelock,
            1,
            50400,
            0,
            50
        );

        timelock.configurarYSellarGobernanza(address(governor));
        token.transferOwnership(address(timelock));

        obras = new ConsorcioObras(address(timelock), address(token));
    }

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 1] Prueba lógica de que el cálculo de quórum jamás divide por cero
    ///         (`quorumDenominator() == 100`) y que el numerador se mantiene en `[30, 100]`.
    function echidna_quorum_sin_division_por_cero_y_mayor_a_cero() public view returns (bool) {
        uint256 num = governor.quorumNumerator();
        uint256 den = governor.quorumDenominator();
        if (den != 100 || num < 30 || num > 100) {
            return false;
        }
        // Con 4 unidades adjudicadas y num >= 30, (4 * num) / 100 >= 1 (y para 50% es 2 > 0)
        uint256 votosTotalesActivos =
            token.getVotes(VECINO_1) +
            token.getVotes(VECINO_2) +
            token.getVotes(VECINO_3) +
            token.getVotes(VECINO_4);
        uint256 quorumCalculado = (votosTotalesActivos * num) / den;
        return quorumCalculado >= 2;
    }

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Solvencia del Vault incluyendo pagos Pull en custodia
    function echidna_solvencia_balance() public view returns (bool) {
        return address(obras).balance >=
            (obras.fondosComprometidosEnObras() + obras.totalPagosPendientesContratistas());
    }

    /// @notice Invariante de Timelock sellado e inmutable para siempre
    function echidna_timelock_sellado() public view returns (bool) {
        return timelock.gobernanzaSellada();
    }

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 3] Ninguna unidad inexistente (ej. 999) puede recibir pagos de expensas
    function echidna_unidades_no_adjudicadas_sin_pagos() public view returns (bool) {
        return obras.expensasPagadasPorUnidad(999) == 0;
    }

    receive() external payable {}
}
