// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioTimelock} from "../contracts/ConsorcioTimelock.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

/**
 * @title DeployConsorcioDAO
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Script determinístico de despliegue canónico V2 y ejecución del flujo principal en Ethereum Sepolia.
 * @dev Incorpora las correcciones de la mentoría docente:
 *      - [CORRECCIÓN DOCENTE - PUNTO 1]: `QUORUM_PERCENTAGE = 50` (50% de quórum estatutario, mínimo 30%).
 *      - [CORRECCIÓN DOCENTE - PUNTO 2]: `ConsorcioObras` con soporte híbrido Push + Pull Fallback (`retirarPagoContratista`).
 *      - [CORRECCIÓN DOCENTE - PUNTO 3]: `ConsorcioObras` recibe `(address(timelock), address(votes))` para validar unidades.
 *      - [CORRECCIÓN DOCENTE - PUNTO 5]: `ConsorcioGovernor` con `cancelarPropuestaEnCola` durante `minDelay`.
 *      - [CORRECCIÓN DOCENTE - PUNTO 6]: `ConsorcioVotes` con doble vía `onlyRegistradorOrOwner`.
 */
contract DeployConsorcioDAO is Script {
    // Parámetros de gobernanza para demostración ágil en Sepolia Testnet
    uint48 public constant VOTING_DELAY = 10; // 10 segundos de deliberación previa
    uint32 public constant VOTING_PERIOD = 300; // 5 minutos de ventana de votación en testnet
    uint256 public constant PROPOSAL_THRESHOLD = 0; // Cualquier vecino puede proponer
    uint256 public constant QUORUM_PERCENTAGE = 50; // [CORRECCIÓN DOCENTE - PUNTO 1] 50% de quórum estatutario
    uint256 public constant MIN_DELAY = 60; // 60 segundos de retardo en Timelock para pruebas en Sepolia

    // Direcciones secundarias determinísticas de vecinos del consorcio
    address public constant VECINO_LOTE_102 = 0x85E4E16Bd367E4259537269633DA9a6Aa4cf95a3;
    address public constant VECINO_LOTE_103 = 0xe6eF3a317f91A0a44eB097c8e68B49CcF9E63895;
    address public constant VECINO_LOTE_104 = 0x3d67BC03e6E562079BfC96Dd2bb52e6D7B78CafC;

    error VerificacionPostSelladoFallida();

    function run()
        external
        returns (
            ConsorcioVotes votes,
            ConsorcioTimelock timelock,
            ConsorcioGovernor governor,
            ConsorcioObras obras,
            uint256 proposalId
        )
    {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerPrivateKey != 0 ? vm.addr(deployerPrivateKey) : msg.sender;

        console.log("==================================================================");
        console.log("DESPLIEGUE CANONICO V2 ADM-CONSORCIOS (ConsorcioDAO) EN SEPOLIA");
        console.log("Deployer / Vecino Lote 101 / Registrador / Guardian:", deployer);
        console.log("==================================================================");

        if (deployerPrivateKey != 0) {
            vm.startBroadcast(deployerPrivateKey);
        } else {
            vm.startBroadcast(deployer);
        }

        // 1. Desplegar ConsorcioVotes (ERC721Votes + Ownable2Step + Registrador)
        votes = new ConsorcioVotes(deployer);
        console.log("1. ConsorcioVotes desplegado en:   ", address(votes));

        // 2a. Adjudicar Unidad Funcional 101 al Deployer
        votes.adjudicarUnidad(101, deployer, 100);
        console.log("2a. Unidad Funcional 101 adjudicada a deployer");

        // 3. Desplegar ConsorcioTimelock (intercalado para avanzar block.timestamp antes del siguiente checkpoint de Votes)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new ConsorcioTimelock(MIN_DELAY, proposers, executors, deployer);
        console.log("3. ConsorcioTimelock desplegado en:", address(timelock));

        // 2b. Adjudicar Unidad Funcional 102 al Deployer (2 votos = 50% de 4 unidades para alcanzar quórum exacto de 2 votos)
        votes.adjudicarUnidad(102, deployer, 100);
        console.log("2b. Unidad Funcional 102 adjudicada a deployer");

        // 4. Desplegar ConsorcioGovernor con QUORUM_PERCENTAGE = 50% (intercalado para avanzar block.timestamp)
        governor = new ConsorcioGovernor(
            IVotes(address(votes)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENTAGE
        );
        console.log("4. ConsorcioGovernor desplegado en:", address(governor));

        // 2c. Adjudicar Unidad Funcional 103 a Vecino Lote 103
        votes.adjudicarUnidad(103, VECINO_LOTE_103, 100);
        console.log("2c. Unidad Funcional 103 adjudicada a Vecino 103");

        // 5. Verificar identidad del Governor y sellar atómicamente el Timelock (intercalado para avanzar block.timestamp)
        if (address(governor.token()) != address(votes) || governor.timelock() != address(timelock)) {
            revert VerificacionPostSelladoFallida();
        }
        timelock.configurarYSellarGobernanza(address(governor));
        if (
            timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer) ||
            timelock.hasRole(timelock.PROPOSER_ROLE(), deployer) ||
            !timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor))
        ) {
            revert VerificacionPostSelladoFallida();
        }
        console.log("5. Timelock sellado atomicamente: DEFAULT_ADMIN_ROLE revocado para deployer");

        // 2d. Adjudicar Unidad Funcional 104 a Vecino Lote 104 (Total = 4 unidades funcionales, Quórum 50% = 2 votos)
        votes.adjudicarUnidad(104, VECINO_LOTE_104, 100);
        console.log("2d. Unidad Funcional 104 adjudicada a Vecino 104 (Total 4 unidades)");

        // 6. Iniciar transferencia en 2 pasos (Ownable2Step) de ConsorcioVotes al Timelock
        votes.transferOwnership(address(timelock));
        console.log("6. Ownable2Step iniciado: pendingOwner de ConsorcioVotes =", votes.pendingOwner());

        // 7. Desplegar ConsorcioObras V2 (recibe timelock + votes)
        obras = new ConsorcioObras(address(timelock), address(votes));
        console.log("7. ConsorcioObras desplegado en:   ", address(obras));

        // 8. Flujo Principal On-Chain Paso A: Pago real de expensas de la Unidad 101 al Vault
        uint256 montoExpensasDemo = 0.001 ether;
        obras.pagarExpensas{value: montoExpensasDemo}(101, "Expensas Ordinarias Octubre 2026 - Lote 101");
        console.log("8. Expensas abonadas al Vault por Lote 101 (wei):", montoExpensasDemo);

        // 9. Flujo Principal On-Chain Paso B: Crear Propuesta de Obra #1 en ConsorcioGovernor
        uint256 presupuestoObraDemo = 0.0005 ether;
        address[] memory targets = new address[](1);
        targets[0] = address(obras);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            (
                "Reparacion de Luminarias y Acceso Principal",
                "Recambio de reflectores LED perimetrales y barrera automatica (Hitos 30/40/30)",
                payable(deployer),
                presupuestoObraDemo
            )
        );
        string memory descripcionPropuesta =
            "Propuesta #1 ConsorcioDAO V2: Aprobar Obra Luminarias LED y Liberar Hito 1 (30%)";

        proposalId = governor.propose(targets, values, calldatas, descripcionPropuesta);
        console.log("9. Propuesta de Obra creada en ConsorcioGovernor! Proposal ID:", proposalId);

        vm.stopBroadcast();
    }
}
