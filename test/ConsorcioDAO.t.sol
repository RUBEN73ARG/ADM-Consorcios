// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioTimelock} from "../contracts/ConsorcioTimelock.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

/**
 * @dev Contrato auxiliar sin `receive()` ni `fallback()` para probar el revert
 *      `FalloTransferenciaETH` cuando un contratista rechaza pagos nativos (CD-06).
 */
contract ContratistaSinReceive {
    // No implementa receive() ni fallback() payable
}

/**
 * @title ConsorcioDAOTest
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Suite integral de pruebas unitarias, de integración, reversión y fuzzing para ConsorcioDAO.
 * @dev Cubre:
 *      - Ciclo completo de 3 hitos (30% -> rendición 1 -> 40% -> rendición 2 -> 30% final)
 *        gobernado íntegramente por ConsorcioGovernor + ConsorcioTimelock.
 *      - Creación de obra en 2 pasos (`crearObra` + `liberarHito1`) y cancelación (`cancelarObra`).
 *      - Pausa de emergencia (`pausarVault` / `reanudarVault`) y cancelación en estado pausado (CD-09).
 *      - Sellado atómico de roles en `ConsorcioTimelock` (`configurarYSellarGobernanza`, CD-01/CD-02/CD-07).
 *      - Transferencia de propiedad en 2 pasos (`Ownable2Step`: `transferOwnership` + `acceptOwnership`, CD-05).
 *      - Reasignación de unidades (`reasignarUnidad`), bloqueo Soulbound y Fuzz Testing de votos.
 *      - Todos los casos de `revert` con Custom Errors en los 4 contratos.
 */
contract ConsorcioDAOTest is Test {
    ConsorcioVotes internal votes;
    ConsorcioTimelock internal timelock;
    ConsorcioGovernor internal governor;
    ConsorcioObras internal obras;

    address internal vecino1;
    address internal vecino2;
    address internal vecino3;
    address internal contratista;

    uint48 internal constant VOTING_DELAY = 10; // 10 segundos
    uint32 internal constant VOTING_PERIOD = 3600; // 1 hora
    uint256 internal constant PROPOSAL_THRESHOLD = 0;
    uint256 internal constant QUORUM_PERCENTAGE = 4; // 4%
    uint256 internal constant MIN_DELAY = 1 days; // 86400 segundos

    function setUp() public {
        vecino1 = makeAddr("vecino1");
        vecino2 = makeAddr("vecino2");
        vecino3 = makeAddr("vecino3");
        contratista = makeAddr("contratista");

        // 1. Despliegue de ConsorcioVotes (owner inicial = address(this))
        votes = new ConsorcioVotes(address(this));

        // 2. Adjudicación de unidades ANTES de sellar/transferir (mitigación CD-01)
        votes.adjudicarUnidad(101, vecino1, 100);
        votes.adjudicarUnidad(102, vecino2, 100);
        votes.adjudicarUnidad(103, vecino3, 100);

        // 3. Despliegue de ConsorcioTimelock con listas vacías (mitigación CD-02)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new ConsorcioTimelock(MIN_DELAY, proposers, executors, address(this));

        // 4. Despliegue de ConsorcioGovernor
        governor = new ConsorcioGovernor(
            IVotes(address(votes)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENTAGE
        );

        // 5. Sellado atómico de roles en Timelock (mitigación CD-02 / CD-07)
        timelock.configurarYSellarGobernanza(address(governor));

        // 6. Despliegue de ConsorcioObras
        obras = new ConsorcioObras(address(timelock));

        // 7. Fondeo inicial de expensas de los 3 vecinos (15 ETH en total)
        vm.deal(vecino1, 10 ether);
        vm.deal(vecino2, 10 ether);
        vm.deal(vecino3, 10 ether);

        vm.prank(vecino1);
        obras.pagarExpensas{value: 5 ether}(101, "Expensas Octubre 2026 - Lote 101");

        vm.prank(vecino2);
        obras.pagarExpensas{value: 5 ether}(102, "Expensas Octubre 2026 - Lote 102");

        vm.prank(vecino3);
        obras.pagarExpensas{value: 5 ether}(103, "Expensas Octubre 2026 - Lote 103");

        // Avanzamos 1 segundo para consolidar el checkpoint de votos EIP-6372
        vm.warp(block.timestamp + 1);
    }

    // =========================================================================
    // Helper Interno para Ejecutar Propuestas de Gobernanza Completas
    // =========================================================================

    function _proponerVotarYEjecutar(
        address target,
        uint256 value,
        bytes memory data,
        string memory descripcion
    ) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;

        vm.prank(vecino1);
        proposalId = governor.propose(targets, values, calldatas, descripcion);

        // Avanzar más allá del votingDelay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Votan vecino1 y vecino2 a favor (2 de 3 unidades = 66.6% > 4% quórum)
        vm.prank(vecino1);
        governor.castVote(proposalId, 1);
        vm.prank(vecino2);
        governor.castVote(proposalId, 1);

        // Avanzar más allá del votingPeriod
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // Encolar en ConsorcioTimelock
        bytes32 descHash = keccak256(bytes(descripcion));
        governor.queue(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Avanzar más allá del minDelay del Timelock y ejecutar
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // =========================================================================
    // 1. Test de Flujo Principal Completo (3 Hitos: 30% -> 40% -> 30%)
    // =========================================================================

    function test_FlujoCompletoObraTresHitos() public {
        uint256 presupuestoObra = 10 ether;
        (uint256 esperadoHito1, uint256 esperadoHito2, uint256 esperadoHito3) =
            obras.calcularDesgloseHitos(presupuestoObra);

        assertEq(esperadoHito1, 3 ether);
        assertEq(esperadoHito2, 4 ether);
        assertEq(esperadoHito3, 3 ether);

        // --- ETAPA 1: Aprobar Obra y Liberar Hito 1 (30% = 3 ETH) vía Gobernanza ---
        bytes memory dataHito1 = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            (
                "Reparacion Integral Pileta",
                "Cambio de filtros, venecitas y pintura perimetral",
                payable(contratista),
                presupuestoObra
            )
        );
        _proponerVotarYEjecutar(address(obras), 0, dataHito1, "Propuesta #1: Aprobar Obra Pileta y Hito 1");

        assertEq(obras.totalObras(), 1);
        assertEq(contratista.balance, 3 ether);
        assertEq(obras.fondosComprometidosEnObras(), 7 ether);
        assertEq(obras.saldoLibreDisponible(), 5 ether); // 15 ETH iniciales - 10 ETH obra

        // --- ETAPA 2: Contratista Rinde Cuentas del Hito 1 en IPFS ---
        vm.prank(contratista);
        obras.rendirCuentasHito1(1, "ipfs://QmFacturasMaterialesHito1");

        // --- ETAPA 3: Votar y Liberar Hito 2 (40% = 4 ETH) vía Gobernanza ---
        bytes memory dataHito2 = abi.encodeCall(ConsorcioObras.liberarHito2, (1));
        _proponerVotarYEjecutar(address(obras), 0, dataHito2, "Propuesta #2: Liberar Hito 2 Obra Pileta");

        assertEq(contratista.balance, 7 ether);
        assertEq(obras.fondosComprometidosEnObras(), 3 ether);

        // --- ETAPA 4: Contratista Rinde Cuentas del Hito 2 en IPFS ---
        vm.prank(contratista);
        obras.rendirCuentasHito2(1, "ipfs://QmAvanceIntermedioHito2");

        // --- ETAPA 5: Votar y Liberar Hito 3 Final (30% = 3 ETH) vía Gobernanza ---
        bytes memory dataHito3 = abi.encodeCall(
            ConsorcioObras.liberarHito3Final,
            (1, "ipfs://QmActaRecepcionDefinitivaObra1")
        );
        _proponerVotarYEjecutar(address(obras), 0, dataHito3, "Propuesta #3: Liquidacion Final Hito 3");

        assertEq(contratista.balance, 10 ether);
        assertEq(obras.fondosComprometidosEnObras(), 0);
        assertEq(address(obras).balance, 5 ether);

        (
            uint256 id,
            ,
            ,
            address adminObra,
            uint256 pTotal,
            uint256 mLiberado,
            ConsorcioObras.EstadoObra estadoFinal,
            string memory cid1,
            string memory cid2,
            string memory cidActa
        ) = obras.obras(1);

        assertEq(id, 1);
        assertEq(adminObra, contratista);
        assertEq(pTotal, 10 ether);
        assertEq(mLiberado, 10 ether);
        assertEq(uint8(estadoFinal), uint8(ConsorcioObras.EstadoObra.Finalizada));
        assertEq(cid1, "ipfs://QmFacturasMaterialesHito1");
        assertEq(cid2, "ipfs://QmAvanceIntermedioHito2");
        assertEq(cidActa, "ipfs://QmActaRecepcionDefinitivaObra1");
    }

    // =========================================================================
    // 2. Creación en 2 pasos, Cancelación y Freno de Emergencia (Pausable)
    // =========================================================================

    function test_CrearEnDosPasosYCancelarDurantePausa() public {
        // Crear obra sin liberar aún el Hito 1
        vm.prank(address(timelock));
        uint256 obraId = obras.crearObra("Luminarias LED", "Recambio general", payable(contratista), 6 ether);
        assertEq(obraId, 1);
        assertEq(obras.fondosComprometidosEnObras(), 6 ether);

        // Liberar Hito 1 en un segundo paso (30% = 1.8 ETH)
        vm.prank(address(timelock));
        obras.liberarHito1(1);
        assertEq(contratista.balance, 1.8 ether);
        assertEq(obras.fondosComprometidosEnObras(), 4.2 ether);

        // Pausar el Vault ante emergencia
        vm.prank(address(timelock));
        obras.pausarVault();
        assertTrue(obras.paused());

        // Con el Vault pausado, pagarExpensas debe revertir con EnforcedPause
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(vecino1);
        obras.pagarExpensas{value: 1 ether}(101, "Intento en pausa");

        // CD-09: cancelarObra funciona incluso en pausa para recuperar reservas contables
        vm.prank(address(timelock));
        obras.cancelarObra(1);
        assertEq(obras.fondosComprometidosEnObras(), 0);

        // Reanudar el Vault
        vm.prank(address(timelock));
        obras.reanudarVault();
        assertFalse(obras.paused());
    }

    // =========================================================================
    // 3. Pruebas de ConsorcioVotes (ERC721Votes, Reasignación, Ownable2Step)
    // =========================================================================

    function test_ConsorcioVotes_ReasignacionYOwnable2Step() public {
        address comprador = makeAddr("comprador");

        // Verificar estado inicial del Lote 101
        assertEq(votes.propietarioDeUnidad(101), vecino1);
        assertEq(votes.getVotes(vecino1), 1);
        assertEq(votes.clock(), uint48(block.timestamp));
        assertEq(votes.CLOCK_MODE(), "mode=timestamp");

        // Reasignar unidad 101 por compraventa escriturada
        votes.reasignarUnidad(101, comprador);
        assertEq(votes.propietarioDeUnidad(101), comprador);
        assertEq(votes.getVotes(vecino1), 0);
        assertEq(votes.getVotes(comprador), 1);

        // Habilitar y deshabilitar transferencias estatutarias
        votes.configurarTransferencias(true);
        assertTrue(votes.transferenciasHabilitadas());
        vm.prank(comprador);
        votes.transferFrom(comprador, vecino1, 101);
        assertEq(votes.propietarioDeUnidad(101), vecino1);

        votes.configurarTransferencias(false);
        assertFalse(votes.transferenciasHabilitadas());

        // CD-05: Transferencia de propiedad en 2 pasos (Ownable2Step) hacia el Timelock
        votes.transferOwnership(address(timelock));
        assertEq(votes.owner(), address(this)); // Sigue siendo address(this) hasta aceptar
        assertEq(votes.pendingOwner(), address(timelock));

        vm.prank(address(timelock));
        votes.acceptOwnership();
        assertEq(votes.owner(), address(timelock));
    }

    function testFuzz_ReasignacionUnidadMantieneVotosYPropiedad(address nuevoVecino) public {
        vm.assume(nuevoVecino != address(0));
        vm.assume(nuevoVecino != vecino1);

        uint256 votosAntesNuevo = votes.getVotes(nuevoVecino);
        uint256 votosAntesSaliente = votes.getVotes(vecino1);

        votes.reasignarUnidad(101, nuevoVecino);

        assertEq(votes.propietarioDeUnidad(101), nuevoVecino);
        assertEq(votes.getVotes(vecino1), votosAntesSaliente - 1);
        assertEq(votes.getVotes(nuevoVecino), votosAntesNuevo + 1);
    }

    // =========================================================================
    // 4. Pruebas de Reversión (Custom Errors en los 4 Contratos)
    // =========================================================================

    function test_Reverts_ConsorcioVotes() public {
        vm.expectRevert(ConsorcioVotes.DireccionInvalida.selector);
        votes.adjudicarUnidad(201, address(0), 100);

        vm.expectRevert(ConsorcioVotes.CuotaParteInvalida.selector);
        votes.adjudicarUnidad(201, vecino1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(ConsorcioVotes.UnidadYaAsignada.selector, 101, vecino1)
        );
        votes.adjudicarUnidad(101, vecino2, 100);

        vm.expectRevert(ConsorcioVotes.DireccionInvalida.selector);
        votes.reasignarUnidad(999, vecino2); // unidad 999 no adjudicada

        vm.expectRevert(ConsorcioVotes.DireccionInvalida.selector);
        votes.reasignarUnidad(101, address(0));

        vm.expectRevert(ConsorcioVotes.TokenIntransferibleEntreParticulares.selector);
        vm.prank(vecino1);
        votes.transferFrom(vecino1, vecino2, 101);
    }

    function test_Reverts_ConsorcioTimelock_Y_ConsorcioGovernor() public {
        // En un Timelock aún no sellado, configurar con address(0) revierte
        ConsorcioTimelock nuevoTl =
            new ConsorcioTimelock(MIN_DELAY, new address[](0), new address[](0), address(this));

        vm.expectRevert(ConsorcioTimelock.DireccionGovernorInvalida.selector);
        nuevoTl.configurarYSellarGobernanza(address(0));

        // Validaciones de constructor de ConsorcioGovernor (GovernorSettings revierte con GovernorInvalidVotingPeriod(0))
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidVotingPeriod.selector, 0));
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 0, 0, 4);

        vm.expectRevert(abi.encodeWithSelector(ConsorcioGovernor.QuorumInvalido.selector, 2));
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 3600, 0, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("GovernorInvalidQuorumFraction(uint256,uint256)")), 101, 100
            )
        );
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 3600, 0, 101);
    }

    function test_Reverts_ConsorcioObras() public {
        // Constructor con address(0)
        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        new ConsorcioObras(address(0));

        // Expensas inválidas
        vm.expectRevert(ConsorcioObras.UnidadInvalida.selector);
        vm.prank(vecino1);
        obras.pagarExpensas{value: 1 ether}(0, "Unidad 0");

        vm.expectRevert(ConsorcioObras.MontoInvalido.selector);
        vm.prank(vecino1);
        obras.pagarExpensas{value: 0}(101, "Monto 0");

        // Destinatarios circulares o inválidos al crear obra
        vm.startPrank(address(timelock));
        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        obras.crearObra("Obra", "Desc", payable(address(0)), 1 ether);

        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        obras.crearObra("Obra", "Desc", payable(address(obras)), 1 ether);

        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        obras.crearObra("Obra", "Desc", payable(address(timelock)), 1 ether);

        vm.expectRevert(ConsorcioObras.MontoInvalido.selector);
        obras.crearObra("Obra", "Desc", payable(contratista), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ConsorcioObras.FondosInsuficientesEnVault.selector, 15 ether, 20 ether)
        );
        obras.crearObra("Obra Excesiva", "Desc", payable(contratista), 20 ether);

        // Obra inexistente
        vm.expectRevert(abi.encodeWithSelector(ConsorcioObras.ObraInexistente.selector, 99));
        obras.liberarHito1(99);

        // Transiciones de estado inválidas
        uint256 id = obras.aprobarObraYLiberarHito1("Obra 1", "Desc", payable(contratista), 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioObras.EstadoDeObraInvalido.selector,
                id,
                ConsorcioObras.EstadoObra.Hito1Liberado,
                ConsorcioObras.EstadoObra.Hito1Rendido
            )
        );
        obras.liberarHito2(id); // Falla porque aún no rindió cuentas del Hito 1
        vm.stopPrank();

        // Rendición vacía
        vm.expectRevert(ConsorcioObras.RendicionDeCuentasVacia.selector);
        vm.prank(contratista);
        obras.rendirCuentasHito1(id, "");

        // CD-06: FalloTransferenciaETH si el contratista es un contrato sin receive()
        ContratistaSinReceive malContratista = new ContratistaSinReceive();
        vm.prank(address(timelock));
        vm.expectRevert(ConsorcioObras.FalloTransferenciaETH.selector);
        obras.aprobarObraYLiberarHito1("Obra Fallida", "Desc", payable(address(malContratista)), 1 ether);
    }
}
