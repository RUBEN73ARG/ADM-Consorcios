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
 * @dev [CORRECCIÓN DOCENTE - PUNTO 2] Contrato auxiliar sin `receive()` ni `fallback()` payable
 *      para verificar que cuando un contratista es un contrato que rechaza ETH:
 *      1) El hito NO se bloquea al ejecutarse desde el Timelock (se acredita en custodia Pull).
 *      2) El contratista puede luego reclamar sus fondos invocando `retirarPagoContratista(receptor)`.
 */
contract ContratistaSinReceive {
    // No implementa receive() ni fallback() payable (rechaza transferencias directas de ETH)

    function reclamarPagoEnCustodia(ConsorcioObras vault, address payable receptor) external {
        vault.retirarPagoContratista(receptor);
    }
}

/**
 * @title ConsorcioDAOTest
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Suite integral de pruebas unitarias, de integración, reversión y fuzzing para ConsorcioDAO V2.
 * @dev Cubre tanto la operatoria integral original como las 5 correcciones on-chain de la mentoría docente:
 *      - [CORRECCIÓN DOCENTE - PUNTO 1]: Quórum estatutario mínimo del 30% al 50% (desplegado al 50%),
 *        probando que jamás ocurre división por cero y que 1 solo voto no aprueba propuestas en el consorcio.
 *      - [CORRECCIÓN DOCENTE - PUNTO 2]: Esquema Híbrido `Push + Pull Fallback` en `_transferirETH` y retiro
 *        explícito mediante `retirarPagoContratista` cuando el contratista es un contrato que rechaza ETH.
 *      - [CORRECCIÓN DOCENTE - PUNTO 3]: Validación on-chain `propietarioDeUnidad(unidadId) != address(0)`
 *        en `pagarExpensas` (revirtiendo con `UnidadNoAdjudicada`) y soporte de pago por inquilino/tercero.
 *      - [CORRECCIÓN DOCENTE - PUNTO 5]: Cancelación de propuestas en estado `Queued` durante la ventana de
 *        seguridad (`minDelay`) del Timelock mediante `cancelarPropuestaEnCola`.
 *      - [CORRECCIÓN DOCENTE - PUNTO 6]: Doble vía `onlyRegistradorOrOwner` en `ConsorcioVotes` para altas
 *        y reasignaciones de unidades funcionales + rotación de `registrador` por el Timelock.
 */
contract ConsorcioDAOTest is Test {
    ConsorcioVotes internal votes;
    ConsorcioTimelock internal timelock;
    ConsorcioGovernor internal governor;
    ConsorcioObras internal obras;

    address internal vecino1;
    address internal vecino2;
    address internal vecino3;
    address internal vecino4;
    address internal inquilinoLeo;
    address internal contratista;

    uint48 internal constant VOTING_DELAY = 10; // 10 segundos
    uint32 internal constant VOTING_PERIOD = 3600; // 1 hora
    uint256 internal constant PROPOSAL_THRESHOLD = 0;
    uint256 internal constant QUORUM_PERCENTAGE = 50; // [CORRECCIÓN DOCENTE - PUNTO 1] 50% de quórum estatutario
    uint256 internal constant MIN_DELAY = 1 days; // 86400 segundos

    function setUp() public {
        vecino1 = makeAddr("vecino1");
        vecino2 = makeAddr("vecino2");
        vecino3 = makeAddr("vecino3");
        vecino4 = makeAddr("vecino4");
        inquilinoLeo = makeAddr("inquilinoLeo");
        contratista = makeAddr("contratista");

        // 1. Despliegue de ConsorcioVotes (owner y registrador inicial = address(this))
        votes = new ConsorcioVotes(address(this));

        // 2. Adjudicación de 4 unidades funcionales ANTES de sellar/transferir (mitigación CD-01)
        votes.adjudicarUnidad(101, vecino1, 100);
        votes.adjudicarUnidad(102, vecino2, 100);
        votes.adjudicarUnidad(103, vecino3, 100);
        votes.adjudicarUnidad(104, vecino4, 100);

        // 3. Despliegue de ConsorcioTimelock con listas vacías (mitigación CD-02)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new ConsorcioTimelock(MIN_DELAY, proposers, executors, address(this));

        // 4. Despliegue de ConsorcioGovernor con QUORUM_PERCENTAGE = 50% (Corrección Docente Punto 1)
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

        // 6. Despliegue de ConsorcioObras vinculado a Timelock y ConsorcioVotes (Corrección Docente Punto 3)
        obras = new ConsorcioObras(address(timelock), address(votes));

        // 7. Fondeo inicial de expensas de los vecinos (15 ETH en total)
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

        // Votan vecino1 y vecino2 a favor (2 de 4 unidades = 50% >= 50% quórum estatutario)
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
    // 3. Pruebas de las 5 Correcciones On-Chain de la Mentoría Docente
    // =========================================================================

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 1] Verifica que con quórum del 50% y 4 unidades,
     *         `quorum()` exige 2 votos y una propuesta con 1 solo voto fracasa (`Defeated`).
     */
    function test_CorreccionDocente1_QuorumMinimo30Al50NuncaEsCeroNiApruebaConUnSoloVoto() public {
        assertEq(governor.QUORUM_MINIMO(), 30);
        assertEq(governor.quorumNumerator(), 50);
        assertEq(governor.quorumDenominator(), 100);
        assertEq(governor.quorum(block.timestamp - 1), 2); // 50% de 4 unidades = 2 votos

        // Crear propuesta y votar con 1 sola unidad (vecino1)
        address[] memory targets = new address[](1);
        targets[0] = address(obras);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ConsorcioObras.pausarVault, ());

        vm.prank(vecino1);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Propuesta con 1 solo voto");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(vecino1);
        governor.castVote(proposalId, 1); // Solo 1 voto a favor (quórum exige 2)

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        // Debe quedar Defeated porque 1 voto < 2 votos de quórum
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 1] Prueba de lógica / Fuzzing sobre el cálculo de quórum
     *         demostrando que `quorumDenominator() == 100` (jamás divide por cero) y para todo
     *         porcentaje válido `[30, 100]` y consorcio de `>= 4` unidades el quórum nunca es cero.
     */
    function testFuzz_CorreccionDocente1_QuorumLogicaSinDivisionPorCero(
        uint256 porcentajeQuorum,
        uint256 cantidadUnidadesExtras
    ) public {
        porcentajeQuorum = bound(porcentajeQuorum, governor.QUORUM_MINIMO(), governor.QUORUM_MAXIMO());
        cantidadUnidadesExtras = bound(cantidadUnidadesExtras, 0, 50);

        for (uint256 i = 0; i < cantidadUnidadesExtras; i++) {
            votes.adjudicarUnidad(200 + i, vecino1, 100);
        }

        vm.warp(block.timestamp + 10);
        uint256 totalUnidades = 4 + cantidadUnidadesExtras;
        uint256 denominador = governor.quorumDenominator();
        assertEq(denominador, 100);
        assertTrue(denominador > 0);

        uint256 quorumCalculado = (totalUnidades * porcentajeQuorum) / denominador;
        assertGe(quorumCalculado, 1); // Nunca es 0
    }

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 2] Verifica el patrón Híbrido `Push + Pull Fallback`:
     *         si el contratista es un contrato que rechaza ETH (`ContratistaSinReceive`), la ejecución
     *         del hito NO revierte ni bloquea al Timelock; el saldo queda en custodia Pull y luego el
     *         contratista lo retira hacia una billetera operativa con `retirarPagoContratista`.
     */
    function test_CorreccionDocente2_PullFallbackContratistaSinReceiveYRetiroExitoso() public {
        ContratistaSinReceive contratoContratista = new ContratistaSinReceive();
        address billeteraOperativaContratista = makeAddr("billeteraOperativaContratista");

        // Aprobar obra de 1 ETH y liberar Hito 1 (0.3 ETH) hacia un contrato que rechaza ETH
        vm.prank(address(timelock));
        uint256 obraId = obras.aprobarObraYLiberarHito1(
            "Impermeabilizacion Terraza",
            "Membrana geotextil",
            payable(address(contratoContratista)),
            1 ether
        );

        // El Hito 1 NO revirtió: pasó a Hito1Liberado y acreditó 0.3 ETH en custodia Pull
        assertEq(obraId, 1);
        assertEq(address(contratoContratista).balance, 0);
        assertEq(obras.pagosPendientesContratista(address(contratoContratista)), 0.3 ether);
        assertEq(obras.totalPagosPendientesContratistas(), 0.3 ether);
        assertEq(obras.fondosComprometidosEnObras(), 0.7 ether);
        // El saldo libre descuenta tanto el comprometido (0.7) como el Pull pendiente (0.3) = 14 ETH libres
        assertEq(obras.saldoLibreDisponible(), 14 ether);

        // El contratista retira su pago en custodia hacia una billetera EOA que sí recibe ETH
        contratoContratista.reclamarPagoEnCustodia(obras, payable(billeteraOperativaContratista));

        assertEq(billeteraOperativaContratista.balance, 0.3 ether);
        assertEq(obras.pagosPendientesContratista(address(contratoContratista)), 0);
        assertEq(obras.totalPagosPendientesContratistas(), 0);

        // Si intenta retirar de nuevo sin saldo pendiente, revierte con SinPagosPendientes
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioObras.SinPagosPendientes.selector,
                address(contratoContratista)
            )
        );
        contratoContratista.reclamarPagoEnCustodia(obras, payable(billeteraOperativaContratista));
    }

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 3] Verifica que `pagarExpensas` bloquee pagos a unidades
     *         no adjudicadas (`UnidadNoAdjudicada`) pero permita que un inquilino abone la expensa
     *         de una unidad funcional existente y adjudicada.
     */
    function test_CorreccionDocente3_PagarExpensasValidaUnidadAdjudicadaYPermiteInquilino() public {
        vm.deal(inquilinoLeo, 2 ether);

        // 1) Intentar pagar expensas a la unidad 999 (no adjudicada) debe revertir con UnidadNoAdjudicada(999)
        vm.expectRevert(abi.encodeWithSelector(ConsorcioObras.UnidadNoAdjudicada.selector, 999));
        vm.prank(inquilinoLeo);
        obras.pagarExpensas{value: 1 ether}(999, "Unidad inexistente");

        // 2) El inquilino Leo abona las expensas del Lote 102 (adjudicado a vecino2)
        uint256 previoUnidad102 = obras.expensasPagadasPorUnidad(102);
        vm.prank(inquilinoLeo);
        obras.pagarExpensas{value: 1 ether}(102, "Expensas pagadas por Inquilino Leo - Lote 102");

        assertEq(obras.expensasPagadasPorUnidad(102), previoUnidad102 + 1 ether);
        assertEq(obras.expensasPagadasPorVecino(inquilinoLeo), 1 ether);
    }

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 5] Verifica que una propuesta ya aprobada y encolada (`Queued`)
     *         pueda ser cancelada durante la ventana de seguridad (`minDelay`) del Timelock mediante
     *         `cancelarPropuestaEnCola` por el Guardián o por el Proponente original.
     */
    function test_CorreccionDocente5_CancelarPropuestaEnColaDuranteMinDelay() public {
        address[] memory targets = new address[](1);
        targets[0] = address(obras);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            ("Obra con Error Detectado", "Presupuesto erroneo", payable(contratista), 2 ether)
        );
        string memory descripcion = "Propuesta a cancelar en ventana de seguridad del Timelock";
        bytes32 descHash = keccak256(bytes(descripcion));

        // 1) Proponer, votar y encolar en el Timelock
        vm.prank(vecino1);
        uint256 proposalId = governor.propose(targets, values, calldatas, descripcion);

        // Si se intenta usar cancelarPropuestaEnCola antes de estar Queued, revierte con PropuestaNoEncolada
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioGovernor.PropuestaNoEncolada.selector,
                proposalId,
                IGovernor.ProposalState.Pending
            )
        );
        governor.cancelarPropuestaEnCola(targets, values, calldatas, descHash);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(vecino1);
        governor.castVote(proposalId, 1);
        vm.prank(vecino2);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // 2) Durante el minDelay, un tercero no autorizado NO puede cancelarla
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioGovernor.NoAutorizadoParaCancelar.selector,
                vecino3,
                vecino1,
                address(this)
            )
        );
        vm.prank(vecino3);
        governor.cancelarPropuestaEnCola(targets, values, calldatas, descHash);

        // 3) El Guardián (o el proponente vecino1) cancela la propuesta encolada durante la ventana de seguridad
        governor.cancelarPropuestaEnCola(targets, values, calldatas, descHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        // 4) Incluso tras vencer el minDelay, la propuesta ya NO puede ejecutarse
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descHash);
    }

    /**
     * @notice [CORRECCIÓN DOCENTE - PUNTO 6] Verifica el esquema de doble vía (`onlyRegistradorOrOwner`)
     *         en `ConsorcioVotes`: tras transferir el `owner` al `ConsorcioTimelock`, tanto el `registrador`
     *         (en 1 paso) como el `ConsorcioTimelock` (por gobernanza) pueden adjudicar y reasignar unidades.
     */
    function test_CorreccionDocente6_DobleViaRegistradorYTimelockEnConsorcioVotes() public {
        address comprador = makeAddr("comprador");
        address nuevoRegistrador = makeAddr("nuevoRegistrador");

        // Transferir ownership de ConsorcioVotes al Timelock (Ownable2Step)
        votes.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        votes.acceptOwnership();
        assertEq(votes.owner(), address(timelock));
        assertEq(votes.registrador(), address(this));

        // 1) El Registrador sigue pudiendo adjudicar y reasignar en 1 paso (evita deadlock de quórum)
        votes.adjudicarUnidad(105, comprador, 100);
        assertEq(votes.propietarioDeUnidad(105), comprador);

        votes.reasignarUnidad(101, comprador);
        assertEq(votes.propietarioDeUnidad(101), comprador);
        assertEq(votes.getVotes(vecino1), 0);
        assertEq(votes.getVotes(comprador), 2);

        // 2) El Timelock (owner supremo) también puede reasignar unidades y rotar al Registrador
        vm.startPrank(address(timelock));
        votes.reasignarUnidad(101, vecino1);
        assertEq(votes.propietarioDeUnidad(101), vecino1);

        votes.actualizarRegistrador(nuevoRegistrador);
        assertEq(votes.registrador(), nuevoRegistrador);
        vm.stopPrank();

        // 3) Una cuenta sin rol de registrador ni owner revierte con NoAutorizadoParaRegistro
        vm.expectRevert(abi.encodeWithSelector(ConsorcioVotes.NoAutorizadoParaRegistro.selector, vecino2));
        vm.prank(vecino2);
        votes.reasignarUnidad(101, vecino2);
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

        // Validaciones de constructor de ConsorcioGovernor
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidVotingPeriod.selector, 0));
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 0, 0, 50);

        // [CORRECCIÓN DOCENTE - PUNTO 1] Quórum menor a 30% o mayor a 100% revierte con QuorumInvalido
        vm.expectRevert(abi.encodeWithSelector(ConsorcioGovernor.QuorumInvalido.selector, 29));
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 3600, 0, 29);

        vm.expectRevert(abi.encodeWithSelector(ConsorcioGovernor.QuorumInvalido.selector, 101));
        new ConsorcioGovernor(IVotes(address(votes)), nuevoTl, 1, 3600, 0, 101);

        // Actualizar Guardián vía propuesta de gobernanza real (onlyGovernance en OZ v5 verifica la cola _governanceCall)
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, vecino1));
        vm.prank(vecino1);
        governor.actualizarGuardian(vecino4);

        bytes memory dataGuardian = abi.encodeCall(ConsorcioGovernor.actualizarGuardian, (vecino4));
        _proponerVotarYEjecutar(address(governor), 0, dataGuardian, "Propuesta: Rotar Guardian a vecino4");
        assertEq(governor.guardian(), vecino4);
    }

    function test_Reverts_ConsorcioObras() public {
        // Constructor con address(0)
        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        new ConsorcioObras(address(0), address(votes));

        vm.expectRevert(ConsorcioObras.DireccionInvalida.selector);
        new ConsorcioObras(address(timelock), address(0));

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
    }
}
