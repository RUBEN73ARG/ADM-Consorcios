// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================================
//  PoC de Auditoría e Invariantes V2 — ConsorcioDAO (ADM-Consorcios)
//  ============================================================================
//  Harness de invariant testing (Foundry) que valida las INTERACCIONES entre
//  los 4 contratos propios incorporando las correcciones de la mentoría docente.
//
//  Ubicación:           /test/ConsorcioDAOInvariants.t.sol
//  Ejecución:           forge test --match-contract ConsorcioDAOInvariants -vvv
//
//  Invariantes verificados:
//   I1. Solvencia Total:  balance(vault) >= fondosComprometidosEnObras + totalPagosPendientesContratistas
//   I2. Contabilidad:     contabilidad espejo (ghost) == fondosComprometidosEnObras
//   I3. Hitos:            montoLiberado <= presupuestoTotal para toda obra
//   I4. Soulbound:        transferenciasHabilitadas permanece false y toda
//                         transferencia entre particulares revierte
//   I5. Acceso:           ninguna llamada desde cuentas != timelock logra
//                         liberar hitos (vm.expectRevert bajo fuzzing)
//   I6. Quórum Seguro:    [CORRECCIÓN DOCENTE - PUNTO 1] quorumDenominator() == 100 (sin división por cero)
//                         y quorum(timepoint) >= 2 para el consorcio (>= 4 unidades al 50%)
// ============================================================================

import {Test, StdCheats} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioTimelock} from "../contracts/ConsorcioTimelock.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

// ---------------------------------------------------------------------------
// Handler: superficie de llamadas acotada que ejercita las rutas de negocio
// de ConsorcioObras y ConsorcioVotes con actores aleatorios. Lleva una
// contabilidad espejo ("ghost variables") de los fondos comprometidos.
// ---------------------------------------------------------------------------
contract ObrasHandler is CommonBase, StdCheats, StdUtils {
    ConsorcioObras public obras;
    ConsorcioTimelock public timelock;
    ConsorcioVotes public votes;
    address[] public vecinos;

    // ---- Ghost variables (contabilidad espejo) ----
    uint256 public ghostComprometido;
    mapping(uint256 => uint256) public ghostPresupuesto;
    mapping(uint256 => uint256) public ghostLiberado;
    mapping(uint256 => address) public ghostAdminDeObra;
    uint256 public contadorUnidades;

    constructor(
        ConsorcioObras _obras,
        ConsorcioTimelock _timelock,
        ConsorcioVotes _votes,
        address[] memory _vecinos
    ) {
        obras = _obras;
        timelock = _timelock;
        votes = _votes;
        vecinos = _vecinos;
        contadorUnidades = 4; // Inicializado con las 4 unidades adjudicadas en setUp()
    }

    function _vecino(uint256 seed) internal view returns (address) {
        return vecinos[seed % vecinos.length];
    }

    function _estado(uint256 obraId)
        internal
        view
        returns (ConsorcioObras.EstadoObra estado)
    {
        (, , , , , , estado, , , ) = obras.obras(obraId);
    }

    // --- Ingreso de fondos: expensas sobre unidades adjudicadas [CORRECCIÓN DOCENTE - PUNTO 3]
    function act_pagarExpensas(uint256 actorSeed, uint256 unidadId, uint256 monto) external {
        if (obras.paused()) return;
        address actor = _vecino(actorSeed);
        monto = bound(monto, 1, 5 ether);
        unidadId = bound(unidadId, 1, contadorUnidades);
        vm.deal(actor, monto);
        vm.prank(actor);
        obras.pagarExpensas{value: monto}(unidadId, "fuzz");
    }

    // --- Ingreso de fondos: receive() directo
    function act_aporteDirecto(uint256 actorSeed, uint256 monto) external {
        if (obras.paused()) return;
        address actor = _vecino(actorSeed);
        monto = bound(monto, 1, 5 ether);
        vm.deal(actor, monto);
        vm.prank(actor);
        (bool ok, ) = address(obras).call{value: monto}("");
        ok;
    }

    // --- Creación de obra en 2 pasos (Timelock)
    function act_crearObra(uint256 presupuesto, uint256 contratistaSeed) external {
        if (obras.paused()) return;
        uint256 libre = obras.saldoLibreDisponible();
        if (libre == 0) return;
        presupuesto = bound(presupuesto, 1, libre);
        address contratista = _vecino(contratistaSeed);
        vm.prank(address(timelock));
        uint256 obraId = obras.crearObra("Obra Fuzz", "desc", payable(contratista), presupuesto);
        ghostPresupuesto[obraId] = presupuesto;
        ghostAdminDeObra[obraId] = contratista;
        ghostComprometido += presupuesto;
    }

    // --- Creación de obra + liberación atómica del Hito 1 (Timelock)
    function act_aprobarObraYLiberarHito1(uint256 presupuesto, uint256 contratistaSeed) external {
        if (obras.paused()) return;
        uint256 libre = obras.saldoLibreDisponible();
        if (libre == 0) return;
        presupuesto = bound(presupuesto, 1, libre);
        address contratista = _vecino(contratistaSeed);
        vm.prank(address(timelock));
        uint256 obraId =
            obras.aprobarObraYLiberarHito1("Obra Fuzz", "desc", payable(contratista), presupuesto);
        uint256 hito1 = (presupuesto * 30) / 100;
        ghostPresupuesto[obraId] = presupuesto;
        ghostAdminDeObra[obraId] = contratista;
        ghostLiberado[obraId] = hito1;
        ghostComprometido += presupuesto - hito1;
    }

    // --- Hito 1 (30%)
    function act_liberarHito1(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        if (obras.paused()) return;
        if (_estado(obraId) != ConsorcioObras.EstadoObra.AprobadaPendienteHito1) return;
        vm.prank(address(timelock));
        obras.liberarHito1(obraId);
        uint256 hito1 = (ghostPresupuesto[obraId] * 30) / 100;
        ghostLiberado[obraId] += hito1;
        ghostComprometido -= hito1;
    }

    // --- Rendición de cuentas Hito 1 (solo el admin de la obra)
    function act_rendirCuentasHito1(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        if (obras.paused()) return;
        if (_estado(obraId) != ConsorcioObras.EstadoObra.Hito1Liberado) return;
        vm.prank(ghostAdminDeObra[obraId]);
        obras.rendirCuentasHito1(obraId, "ipfs://QmRendicion1");
    }

    // --- Hito 2 (40%)
    function act_liberarHito2(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        if (obras.paused()) return;
        if (_estado(obraId) != ConsorcioObras.EstadoObra.Hito1Rendido) return;
        vm.prank(address(timelock));
        obras.liberarHito2(obraId);
        uint256 hito2 = (ghostPresupuesto[obraId] * 40) / 100;
        ghostLiberado[obraId] += hito2;
        ghostComprometido -= hito2;
    }

    // --- Rendición de cuentas Hito 2
    function act_rendirCuentasHito2(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        if (obras.paused()) return;
        if (_estado(obraId) != ConsorcioObras.EstadoObra.Hito2Liberado) return;
        vm.prank(ghostAdminDeObra[obraId]);
        obras.rendirCuentasHito2(obraId, "ipfs://QmRendicion2");
    }

    // --- Hito 3 (30% residual + redondeo)
    function act_liberarHito3Final(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        if (obras.paused()) return;
        if (_estado(obraId) != ConsorcioObras.EstadoObra.Hito2Rendido) return;
        uint256 pendiente = ghostPresupuesto[obraId] - ghostLiberado[obraId];
        vm.prank(address(timelock));
        obras.liberarHito3Final(obraId, "ipfs://QmActaFinal");
        ghostLiberado[obraId] += pendiente;
        ghostComprometido -= pendiente;
    }

    // --- Cancelación de obra (válido incluso con vault pausado: CD-09)
    function act_cancelarObra(uint256 obraId) external {
        if (obras.totalObras() == 0) return;
        obraId = bound(obraId, 1, obras.totalObras());
        uint8 e = uint8(_estado(obraId));
        if (e < uint8(ConsorcioObras.EstadoObra.AprobadaPendienteHito1)) return;
        if (e > uint8(ConsorcioObras.EstadoObra.Hito2Rendido)) return;
        uint256 pendiente = ghostPresupuesto[obraId] - ghostLiberado[obraId];
        vm.prank(address(timelock));
        obras.cancelarObra(obraId);
        ghostComprometido -= pendiente;
    }

    // --- Freno de emergencia (Timelock)
    function act_togglePausa(uint256 semilla) external {
        if (semilla % 2 == 0) {
            if (!obras.paused()) {
                vm.prank(address(timelock));
                obras.pausarVault();
            }
        } else {
            if (obras.paused()) {
                vm.prank(address(timelock));
                obras.reanudarVault();
            }
        }
    }

    // --- Intento de liberación SIN ser Timelock (I5: debe revertir siempre)
    function act_intentoNoAutorizado(uint256 obraId, uint256 actorSeed) external {
        obraId = bound(obraId, 1, obras.totalObras() == 0 ? 1 : obras.totalObras());
        vm.expectRevert();
        vm.prank(_vecino(actorSeed));
        obras.liberarHito1(obraId);
    }

    // --- Adjudicación de unidad (registrador u owner de ConsorcioVotes)
    function act_adjudicarUnidad(uint256 vecinoSeed) external {
        contadorUnidades += 1;
        vm.prank(address(votes.registrador()));
        votes.adjudicarUnidad(contadorUnidades, _vecino(vecinoSeed), 100);
    }

    // --- Reasignación oficial por compraventa (registrador u owner)
    function act_reasignarUnidad(uint256 unidadId, uint256 vecinoSeed) external {
        if (contadorUnidades == 0) return;
        unidadId = bound(unidadId, 1, contadorUnidades);
        if (votes.propietarioDeUnidad(unidadId) == address(0)) return;
        vm.prank(address(votes.registrador()));
        votes.reasignarUnidad(unidadId, _vecino(vecinoSeed));
    }

    // --- Transferencia entre particulares (I4: debe revertir siempre)
    function act_transferenciaSoulbound(uint256 unidadId, uint256 vecinoSeed) external {
        if (contadorUnidades == 0) return;
        unidadId = bound(unidadId, 1, contadorUnidades);
        address propietario = votes.propietarioDeUnidad(unidadId);
        if (propietario == address(0)) return;
        vm.expectRevert();
        vm.prank(propietario);
        votes.transferFrom(propietario, _vecino(vecinoSeed), unidadId);
    }
}

// ---------------------------------------------------------------------------
// Suite de invariantes + tests de flujo completo
// ---------------------------------------------------------------------------
contract ConsorcioDAOInvariants is Test {
    ConsorcioVotes internal votes;
    ConsorcioTimelock internal timelock;
    ConsorcioGovernor internal governor;
    ConsorcioObras internal obras;
    ObrasHandler internal handler;

    address internal vecino1;
    address internal vecino2;
    address internal vecino3;
    address internal vecino4;

    function setUp() public {
        vecino1 = makeAddr("vecino1");
        vecino2 = makeAddr("vecino2");
        vecino3 = makeAddr("vecino3");
        vecino4 = makeAddr("vecino4");

        address[] memory vecinos = new address[](4);
        vecinos[0] = vecino1;
        vecinos[1] = vecino2;
        vecinos[2] = vecino3;
        vecinos[3] = vecino4;

        // 1) NFT de gobernanza (owner y registrador inicial = este contrato de test)
        votes = new ConsorcioVotes(address(this));

        // 2) Timelock SIN roles en el constructor (CD-02)
        timelock = new ConsorcioTimelock(1 days, new address[](0), new address[](0), address(this));

        // 3) Governor: delay 1s, votación 3600s, umbral 0, quórum 50% [CORRECCIÓN DOCENTE - PUNTO 1]
        governor =
            new ConsorcioGovernor(IVotes(address(votes)), timelock, 1, 3600, 0, 50);

        // 4) Vault de obras vinculado a Timelock y ConsorcioVotes [CORRECCIÓN DOCENTE - PUNTO 3]
        obras = new ConsorcioObras(address(timelock), address(votes));

        // 5) Sellado atómico de gobernanza (msg.sender = admin temporal)
        timelock.configurarYSellarGobernanza(address(governor));

        // 6) Adjudicación de 4 unidades funcionales (NFTs auto-delegados)
        votes.adjudicarUnidad(1, vecino1, 100);
        votes.adjudicarUnidad(2, vecino2, 100);
        votes.adjudicarUnidad(3, vecino3, 100);
        votes.adjudicarUnidad(4, vecino4, 100);

        // 7) Liquidez inicial del vault
        vm.deal(vecino1, 10 ether);
        vm.prank(vecino1);
        obras.pagarExpensas{value: 10 ether}(1, "Expensas iniciales");

        vm.warp(block.timestamp + 2);

        handler = new ObrasHandler(obras, timelock, votes, vecinos);
        targetContract(address(handler));
    }

    // ============================ INVARIANTES ================================

    /// I1. El vault siempre puede respaldar el 100% de las obras en curso + pagos Pull en custodia.
    function invariant_SolvenciaDelVault() public view {
        assertGe(
            address(obras).balance,
            obras.fondosComprometidosEnObras() + obras.totalPagosPendientesContratistas()
        );
    }

    /// I2. La contabilidad espejo del handler coincide con el storage real.
    function invariant_ContabilidadEspejo() public view {
        assertEq(handler.ghostComprometido(), obras.fondosComprometidosEnObras());
    }

    /// I3. Ninguna obra libera más que su presupuesto total (30+40+30 = 100%).
    function invariant_LiberadoNoSuperaPresupuesto() public view {
        for (uint256 i = 1; i <= obras.totalObras(); i++) {
            (, , , , uint256 presupuestoTotal, uint256 montoLiberado, , , ,) = obras.obras(i);
            assertLe(montoLiberado, presupuestoTotal);
        }
    }

    /// I4a. El flag Soulbound nunca se habilita en el harness.
    function invariant_TransferenciasSiguenDeshabilitadas() public view {
        assertFalse(votes.transferenciasHabilitadas());
    }

    /// I4b. 1 NFT adjudicado = 1 voto: el supply de votos es invariante a reasignaciones.
    function invariant_SupplyIgualAdjudicaciones() public view {
        uint256 sumaBalances = votes.balanceOf(vecino1) + votes.balanceOf(vecino2)
            + votes.balanceOf(vecino3) + votes.balanceOf(vecino4);
        assertEq(sumaBalances, handler.contadorUnidades());
    }

    /// I6. [CORRECCIÓN DOCENTE - PUNTO 1] El denominador de quórum es siempre 100 (jamás divide por cero)
    ///     y el quórum requerido es siempre >= 2 votos (nunca 0).
    function invariant_QuorumNuncaEsCeroNiDividePorCero() public view {
        assertEq(governor.quorumDenominator(), 100);
        assertGe(governor.quorumNumerator(), 30);
        assertGe(governor.quorum(block.timestamp - 1), 2);
    }

    // ======================= TESTS DE INTERACCIÓN ============================

    /// Flujo de punta a punta: propuesta -> voto -> queue -> execute -> Hito 1.
    function test_FlujoCompleto_Governor_Timelock_Obras() public {
        uint256 presupuesto = 5 ether;

        address[] memory targets = new address[](1);
        targets[0] = address(obras);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            ("Reparacion Pileta", "Cambio de filtros", payable(vecino2), presupuesto)
        );
        string memory desc = "Obra: Reparacion de Pileta";

        // Propuesta (umbral 0: cualquier vecino puede proponer)
        vm.prank(vecino3);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);

        // Votación tras el votingDelay (2 votos de 4 = 50% >= 50% quórum)
        vm.warp(block.timestamp + 2);
        vm.prank(vecino1);
        governor.castVote(proposalId, 1); // A favor
        vm.prank(vecino2);
        governor.castVote(proposalId, 1); // A favor

        // Cierre de votación y encolado en el Timelock
        vm.warp(block.timestamp + 3601);
        vm.prank(vecino1);
        governor.queue(targets, values, calldatas, keccak256(bytes(desc)));

        // Ventana del timelock (minDelay = 1 día) y ejecución permisionless
        vm.warp(block.timestamp + 1 days + 2);
        vm.prank(vecino4); // EXECUTOR_ROLE = address(0): cualquiera ejecuta
        governor.execute(targets, values, calldatas, keccak256(bytes(desc)));

        // El Timelock liberó el Hito 1 (30%) al contratista
        (, , , , uint256 pTotal, uint256 liberado, ConsorcioObras.EstadoObra estado, , ,) =
            obras.obras(1);
        assertEq(pTotal, presupuesto);
        assertEq(liberado, (presupuesto * 30) / 100);
        assertEq(uint8(estado), uint8(ConsorcioObras.EstadoObra.Hito1Liberado));
        assertEq(address(obras).balance, 10 ether - (presupuesto * 30) / 100);
        assertEq(vecino2.balance, (presupuesto * 30) / 100);
        assertEq(obras.fondosComprometidosEnObras(), presupuesto - (presupuesto * 30) / 100);
    }

    /// [CORRECCIÓN DOCENTE - PUNTO 3] pagarExpensas rechaza unidadId inexistente (UnidadNoAdjudicada).
    function test_CorreccionDocente3_ExpensasSobreUnidadInexistenteRevierte() public {
        assertEq(votes.propietarioDeUnidad(999), address(0)); // unidad jamás adjudicada
        vm.deal(vecino1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ConsorcioObras.UnidadNoAdjudicada.selector, 999));
        vm.prank(vecino1);
        obras.pagarExpensas{value: 1 ether}(999, "Pago a unidad inexistente");
    }

    /// Solo el Timelock puede mover fondos del vault (control de acceso).
    function test_SoloTimelockLiberarHitos() public {
        vm.prank(address(timelock));
        obras.crearObra("Obra", "desc", payable(vecino2), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioObras.SoloTimelockAutorizado.selector, vecino1, address(timelock)
            )
        );
        vm.prank(vecino1);
        obras.liberarHito1(1);
    }

    /// Solo el admin de la obra puede rendir cuentas.
    function test_RendicionSoloAdminDeObra() public {
        vm.prank(address(timelock));
        obras.crearObra("Obra", "desc", payable(vecino2), 1 ether);
        vm.prank(address(timelock));
        obras.liberarHito1(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsorcioObras.SoloAdministradorDeObra.selector, vecino3, vecino2
            )
        );
        vm.prank(vecino3); // NO es el admin de la obra
        obras.rendirCuentasHito1(1, "ipfs://QmX");
    }

    /// Soulbound: el propietario de un NFT no puede transferirlo libremente.
    function test_TransferenciaSoulboundRevierte() public {
        vm.expectRevert(ConsorcioVotes.TokenIntransferibleEntreParticulares.selector);
        vm.prank(vecino1);
        votes.transferFrom(vecino1, vecino2, 1);
    }

    /// CD-02: tras el sellado, nadie administra el Timelock manualmente.
    function test_SelladoRevocaAdminYBloqueaReejecucion() public {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        vm.expectRevert();
        timelock.configurarYSellarGobernanza(address(1)); // gobernanza ya sellada
    }
}
