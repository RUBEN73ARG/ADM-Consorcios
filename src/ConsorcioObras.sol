// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @notice Interfaz mínima para consultar en `ConsorcioVotes` si una unidad funcional existe y está adjudicada.
 * @dev [CORRECCIÓN DOCENTE - PUNTO 3] Utilizada por `ConsorcioObras.pagarExpensas` para impedir pagos
 *      imputados a unidades funcionales inexistentes o no empadronadas (`address(0)`).
 */
interface IConsorcioVotes {
    function propietarioDeUnidad(uint256 unidadId) external view returns (address);
}

/**
 * @title ConsorcioObras
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Bóveda (Vault) de expensas y custodia por hitos (Milestone Escrow) para obras de espacio común.
 * @dev Inspirado en arquitecturas de bóvedas DAO y custodia por hitos (Escrow):
 *      - SmartInvoice: https://github.com/SmartInvoiceXYZ/smart-invoice
 *      - Web3 Milestone Escrow: https://github.com/hilmikt/web3-milestone-escrow
 *      - DevQuest DAO Vault: https://github.com/xavierScript/devquest-vault
 *
 *      Reglas de negocio y seguridad implementadas:
 *      1. Los vecinos o inquilinos abonan expensas ordinarias/extraordinarias al Vault (`pagarExpensas`).
 *      2. Toda liberación de fondos exige el modificador `onlyTimelock`: ni el Administrador ni un
 *         propietario individual pueden retirar dinero sin una propuesta votada en `ConsorcioGovernor`
 *         y ejecutada tras la ventana de seguridad de `ConsorcioTimelock`.
 *      3. Cada obra divide su presupuesto en 3 hitos estrictos:
 *         - Hito 1 (Anticipo / Materiales): 30% -> Liberado tras la 1ra votación.
 *         - Hito 2 (Avance Intermedio):     40% -> Requiere rendición de cuentas previa del Hito 1
 *                                                  por parte del Administrador y 2da votación.
 *         - Hito 3 (Entrega Final):         30% -> Requiere rendición de cuentas previa del Hito 2
 *                                                  por parte del Administrador y 3ra votación (liquidación).
 *      4. Aplica estrictamente el patrón Checks-Effects-Interactions (CEI), `ReentrancyGuard`, `Pausable`
 *         de emergencia gobernado por el Timelock, validación de existencia de obra (`ObraInexistente`),
 *         bloqueo de direcciones circulares (`address(this)` / `timelock`), cacheo de variables de storage
 *         en memoria y bloques `unchecked` seguros para optimización de gas.
 *
 *      =========================================================================
 *      CORRECCIONES DE MENTORÍA DOCENTE IMPLEMENTADAS EN ESTE CONTRATO:
 *      =========================================================================
 *      1. [CORRECCIÓN DOCENTE - PUNTO 2] (Esquema Pull / Híbrido para liberación de fondos al contratista):
 *         - Observación: Si `administradorOContratista` es un contrato inteligente que rechaza transferencias
 *           nativas de ETH (sin `receive()` payable o que revierte en su fallback), una transferencia `.call`
 *           que revierte bloquea la ejecución de la propuesta en el Timelock (DoS sobre el hito).
 *         - Solución implementada: Patrón Híbrido `Push + Pull Fallback` en `_transferirETH`. Si la transferencia
 *           directa (`.call{value: monto}("")`) tiene éxito, el contratista recibe el ETH en el acto. Si falla
 *           porque el contrato receptor rechaza ETH, la transacción del Timelock NO revierte: el hito avanza
 *           normalmente y el importe queda reservado en `pagosPendientesContratista[destinatario]` (y contabilizado
 *           en `totalPagosPendientesContratistas` para no afectar `saldoLibreDisponible()`). El contratista puede
 *           luego cobrar sus fondos en cualquier momento invocando `retirarPagoContratista(address payable receptor)`
 *           hacia una billetera que sí acepte ETH.
 *
 *      2. [CORRECCIÓN DOCENTE - PUNTO 3] (Validación de unidad adjudicada y pago por terceros en `pagarExpensas`):
 *         - Observación: Revisar si tiene sentido que cualquier billetera pueda atribuir un pago a cualquier unidad
 *           y documentar el motivo legal/operativo.
 *         - Solución implementada: Se inyecta la referencia inmutable `consorcioVotes` y se valida on-chain que
 *           `consorcioVotes.propietarioDeUnidad(unidadId) != address(0)` (revirtiendo con `UnidadNoAdjudicada` si
 *           el lote no existe o no fue adjudicado). Se mantiene intencionalmente abierta la posibilidad de que
 *           cualquier `msg.sender` abone las expensas de una unidad adjudicada porque en la operatoria real de
 *           consorcios (Art. 881 CCyC - Pago por tercero / Locatario) las expensas suelen ser abonadas por el
 *           inquilino, un familiar o una inmobiliaria, registrando simultáneamente el lote beneficiado
 *           (`expensasPagadasPorUnidad[unidadId]`) y quién realizó el desembolso (`expensasPagadasPorVecino[msg.sender]`).
 */
contract ConsorcioObras is ReentrancyGuard, Pausable {
    // =========================================================================
    // Constantes de Hitos (30% - 40% - 30%)
    // =========================================================================

    /// @notice Porcentaje del presupuesto total correspondiente al Hito 1 (Anticipo / Materiales: 30%).
    uint256 public constant PORCENTAJE_HITO_1 = 30;

    /// @notice Porcentaje del presupuesto total correspondiente al Hito 2 (Avance Intermedio: 40%).
    uint256 public constant PORCENTAJE_HITO_2 = 40;

    /// @notice Porcentaje del presupuesto total correspondiente al Hito 3 (Entrega Final: 30%).
    uint256 public constant PORCENTAJE_HITO_3 = 30;

    // =========================================================================
    // Variables de Estado
    // =========================================================================

    /// @notice Dirección inmutable de la bóveda de retardo (`ConsorcioTimelock`), único rol con permiso de ejecución.
    address public immutable timelock;

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 3] Referencia inmutable al padrón `ConsorcioVotes` para validar unidades activas.
    IConsorcioVotes public immutable consorcioVotes;

    /// @notice Contador incremental de obras registradas en el consorcio.
    uint256 public totalObras;

    /// @notice Total de fondos en wei comprometidos en obras activas pendientes de liberar.
    uint256 public fondosComprometidosEnObras;

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Total de fondos en wei acreditados en custodia Pull para contratistas
    ///         cuya recepción directa de ETH falló al liberarse un hito.
    uint256 public totalPagosPendientesContratistas;

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Saldo en wei disponible para retiro Pull por cada contratista.
    mapping(address contratista => uint256 montoPendiente) public pagosPendientesContratista;

    /// @notice Estados secuenciales del ciclo de vida de una obra.
    enum EstadoObra {
        Inexistente,
        AprobadaPendienteHito1,
        Hito1Liberado,
        Hito1Rendido,
        Hito2Liberado,
        Hito2Rendido,
        Finalizada,
        Cancelada
    }

    /// @notice Estructura de datos que almacena la trazabilidad contable y documental de una obra.
    struct Obra {
        uint256 id;
        string nombre;
        string descripcion;
        address payable administradorOContratista;
        uint256 presupuestoTotal;
        uint256 montoLiberado;
        EstadoObra estado;
        string rendicionHito1Cid; // Hash IPFS o URL con facturas/fotos del Hito 1 (30%)
        string rendicionHito2Cid; // Hash IPFS o URL con facturas/fotos del Hito 2 (40%)
        string actaEntregaFinalCid; // Hash IPFS opcional de cierre de obra
    }

    /// @notice Registro de obras por ID (`1 .. totalObras`).
    mapping(uint256 obraId => Obra datosObra) public obras;

    /// @notice Registro histórico de expensas abonadas en wei por cada unidad funcional/lote.
    mapping(uint256 unidadId => uint256 totalPagado) public expensasPagadasPorUnidad;

    /// @notice Registro histórico de expensas abonadas en wei por cada billetera.
    mapping(address vecino => uint256 totalPagado) public expensasPagadasPorVecino;

    // =========================================================================
    // Errores Personalizados (Custom Errors)
    // =========================================================================

    /// @notice Se lanza cuando una cuenta distinta de `ConsorcioTimelock` intenta ejecutar una acción protegida.
    /// @param llamador Dirección que intentó ejecutar la transacción.
    /// @param timelockEsperado Dirección autorizada del contrato `ConsorcioTimelock`.
    error SoloTimelockAutorizado(address llamador, address timelockEsperado);

    /// @notice Se lanza cuando una cuenta distinta del administrador/contratista asignado intenta rendir cuentas.
    /// @param llamador Dirección que intentó presentar la rendición.
    /// @param administradorEsperado Dirección registrada como responsable de la obra.
    error SoloAdministradorDeObra(address llamador, address administradorEsperado);

    /// @notice Se lanza cuando el monto en wei enviado o presupuestado es igual a cero.
    error MontoInvalido();

    /// @notice Se lanza cuando el identificador de unidad funcional es igual a cero.
    error UnidadInvalida();

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 3] Se lanza cuando se intenta pagar expensas de una unidad funcional no adjudicada.
    /// @param unidadId Identificador de la unidad funcional sin propietario en `ConsorcioVotes`.
    error UnidadNoAdjudicada(uint256 unidadId);

    /// @notice Se lanza cuando se proporciona una dirección inválida (`address(0)`, este contrato o el Timelock).
    error DireccionInvalida();

    /// @notice Se lanza cuando se consulta o intenta operar sobre un identificador de obra inexistente.
    /// @param obraId Identificador de obra fuera del rango válido (`0` o `> totalObras`).
    error ObraInexistente(uint256 obraId);

    /// @notice Se lanza cuando el saldo libre del Vault no alcanza para cubrir el presupuesto total de una nueva obra.
    /// @param disponible Saldo libre actual en el Vault (descontando reservas de obras en curso y pagos Pull).
    /// @param requerido Presupuesto total solicitado para la nueva obra.
    error FondosInsuficientesEnVault(uint256 disponible, uint256 requerido);

    /// @notice Se lanza cuando se intenta una transición de estado de obra que no respeta la secuencia de hitos.
    /// @param obraId Identificador de la obra.
    /// @param estadoActual Estado en el que se encuentra actualmente la obra.
    /// @param estadoEsperado Estado requerido para poder ejecutar la operación.
    error EstadoDeObraInvalido(uint256 obraId, EstadoObra estadoActual, EstadoObra estadoEsperado);

    /// @notice Se lanza cuando el administrador intenta presentar una rendición con un CID de IPFS vacío.
    error RendicionDeCuentasVacia();

    /// @notice Se lanza cuando falla la transferencia nativa de ETH durante un retiro explícito (`retirarPagoContratista`).
    error FalloTransferenciaETH();

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Se lanza cuando un contratista sin saldo pendiente invoca `retirarPagoContratista`.
    /// @param contratista Dirección que intentó retirar fondos sin tener pagos en custodia.
    error SinPagosPendientes(address contratista);

    // =========================================================================
    // Eventos de Auditoría en la Blockchain
    // =========================================================================

    /// @notice Se emite cada vez que ingresa un pago de expensas o aporte al Vault.
    /// @param pagador Billetera del vecino o inquilino que realizó el pago.
    /// @param unidadId Identificador de la unidad funcional o lote (`0` si fue transferencia directa).
    /// @param monto Importe abonado en wei.
    /// @param concepto Descripción del período o motivo del pago.
    event ExpensasRecibidas(
        address indexed pagador,
        uint256 indexed unidadId,
        uint256 monto,
        string concepto
    );

    /// @notice Se emite cuando el Timelock registra y reserva el presupuesto para una nueva obra.
    /// @param obraId Identificador único asignado a la obra.
    /// @param nombre Título descriptivo de la obra.
    /// @param administradorOContratista Billetera responsable de ejecutar la obra y rendir cuentas.
    /// @param presupuestoTotal Presupuesto total comprometido en wei (100%).
    event ObraCreada(
        uint256 indexed obraId,
        string nombre,
        address indexed administradorOContratista,
        uint256 presupuestoTotal
    );

    /// @notice Se emite cuando el Timelock libera los fondos de un hito (1, 2 o 3).
    /// @param obraId Identificador de la obra.
    /// @param numeroHito Número de etapa liberada (`1`, `2` o `3`).
    /// @param destinatario Billetera receptora de los fondos.
    /// @param montoLiberado Importe liberado en este hito en wei.
    /// @param acumuladoLiberado Importe total acumulado liberado para esta obra hasta el momento.
    event HitoLiberado(
        uint256 indexed obraId,
        uint8 indexed numeroHito,
        address indexed destinatario,
        uint256 montoLiberado,
        uint256 acumuladoLiberado
    );

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Se emite cuando la transferencia directa de ETH al contratista falla
    ///         y el monto queda resguardado en custodia Pull para retiro posterior vía `retirarPagoContratista`.
    /// @param contratista Dirección del contratista cuyos fondos quedaron en custodia.
    /// @param monto Importe del hito acreditado en custodia en wei.
    /// @param acumuladoPendiente Saldo total pendiente de retiro para ese contratista.
    event PagoContratistaEnCustodia(
        address indexed contratista,
        uint256 monto,
        uint256 acumuladoPendiente
    );

    /// @notice [CORRECCIÓN DOCENTE - PUNTO 2] Se emite cuando un contratista retira exitosamente sus fondos en custodia Pull.
    /// @param contratista Dirección del contratista titular del crédito.
    /// @param receptor Dirección payable donde el contratista decidió recibir el ETH.
    /// @param monto Importe transferido en wei.
    event PagoContratistaRetirado(
        address indexed contratista,
        address indexed receptor,
        uint256 monto
    );

    /// @notice Se emite cuando el administrador presenta en la blockchain los comprobantes IPFS de un hito.
    /// @param obraId Identificador de la obra.
    /// @param numeroHitoRendido Número del hito cuyos comprobantes se presentan (`1` o `2`).
    /// @param administrador Billetera del administrador o contratista que rinde cuentas.
    /// @param comprobantesIpfsCid Hash IPFS o URI de las facturas y fotos de avance.
    event RendicionDeCuentasPresentada(
        uint256 indexed obraId,
        uint8 indexed numeroHitoRendido,
        address indexed administrador,
        string comprobantesIpfsCid
    );

    /// @notice Se emite cuando el Consorcio cancela una obra en curso y libera los fondos no ejecutados.
    /// @param obraId Identificador de la obra cancelada.
    /// @param saldoDescomprometido Monto en wei que vuelve a estar disponible en el saldo libre del Vault.
    event ObraCancelada(uint256 indexed obraId, uint256 saldoDescomprometido);

    // =========================================================================
    // Modificadores de Seguridad
    // =========================================================================

    /**
     * @notice Garantiza que únicamente una propuesta votada en `ConsorcioGovernor` y ejecutada
     *         a través de `ConsorcioTimelock` pueda invocar funciones que comprometen o liberan fondos.
     */
    modifier onlyTimelock() {
        if (msg.sender != timelock) {
            revert SoloTimelockAutorizado(msg.sender, timelock);
        }
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Inicializa la bóveda de obras vinculándola de forma inmutable al `ConsorcioTimelock` y a `ConsorcioVotes`.
     * @param _timelock Dirección del contrato `ConsorcioTimelock`.
     * @param _consorcioVotes Dirección del contrato `ConsorcioVotes` para validar unidades adjudicadas.
     */
    constructor(address _timelock, address _consorcioVotes) {
        if (_timelock == address(0) || _consorcioVotes == address(0)) revert DireccionInvalida();
        timelock = _timelock;
        consorcioVotes = IConsorcioVotes(_consorcioVotes);
    }

    // =========================================================================
    // 0. Controles de Emergencia (Pausable gobernado por ConsorcioTimelock)
    // =========================================================================

    /**
     * @notice Pausa de emergencia las operaciones de egreso y creación de obras en el Vault.
     * @dev Solo puede ser invocada mediante decisión del Consorcio ejecutada por `ConsorcioTimelock`.
     */
    function pausarVault() external onlyTimelock {
        _pause();
    }

    /**
     * @notice Reanuda las operaciones del Vault tras haberse resuelto la contingencia.
     * @dev Solo puede ser invocada mediante decisión del Consorcio ejecutada por `ConsorcioTimelock`.
     */
    function reanudarVault() external onlyTimelock {
        _unpause();
    }

    // =========================================================================
    // 1. Recaudación de Expensas (Ingresos al Vault)
    // =========================================================================

    /**
     * @notice Permite a un propietario, inquilino o tercero autorizado pagar las expensas de una unidad funcional/lote.
     * @dev [CORRECCIÓN DOCENTE - PUNTO 3]:
     *      1. Valida on-chain que la unidad funcional exista y esté adjudicada en el padrón oficial
     *         (`consorcioVotes.propietarioDeUnidad(unidadId) != address(0)`), evitando pagos huérfanos a lotes inexistentes.
     *      2. Permite intencionalmente que cualquier billetera (`msg.sender`) abone la expensa de una unidad adjudicada,
     *         dado que en la práctica consorcial (Art. 881 CCyC - Pago por tercero / Locatario) las expensas ordinarias
     *         son habitualmente pagadas por inquilinos, familiares o administradores de alquileres.
     *      3. Acredita tanto `expensasPagadasPorUnidad[unidadId]` (estado de cuenta del departamento) como
     *         `expensasPagadasPorVecino[msg.sender]` (recibo histórico del pagador).
     * @param unidadId Número de departamento o lote adjudicado (mayor a 0, ej. 101).
     * @param concepto Detalle del período abonado (ej. "Expensas Ordinarias Octubre 2026").
     */
    function pagarExpensas(uint256 unidadId, string calldata concepto) external payable whenNotPaused {
        if (unidadId == 0) revert UnidadInvalida();
        if (msg.value == 0) revert MontoInvalido();
        if (consorcioVotes.propietarioDeUnidad(unidadId) == address(0)) {
            revert UnidadNoAdjudicada(unidadId);
        }

        expensasPagadasPorUnidad[unidadId] += msg.value;
        expensasPagadasPorVecino[msg.sender] += msg.value;

        emit ExpensasRecibidas(msg.sender, unidadId, msg.value, concepto);
    }

    /**
     * @notice Permite recibir transferencias directas de ETH al Vault como canal de aportes extraordinarios genéricos.
     * @dev El pago formal de expensas por lote exige invocar `pagarExpensas(unidadId, concepto)`.
     *      Las transferencias directas a `receive()` acreditan `expensasPagadasPorVecino[msg.sender]`
     *      y emiten `unidadId = 0` en el evento `ExpensasRecibidas` (CD-13).
     */
    receive() external payable {
        expensasPagadasPorVecino[msg.sender] += msg.value;
        emit ExpensasRecibidas(msg.sender, 0, msg.value, "Aporte directo al Vault");
    }

    // =========================================================================
    // 2. Creación de Obras y Liberación de Hito 1 (30% - Anticipo / Materiales)
    // =========================================================================

    /**
     * @notice Aprueba una nueva obra de espacio común y libera inmediatamente el Hito 1 (30%)
     *         al Administrador o contratista tras la 1ra votación del Consorcio.
     * @param nombre Título de la obra (ej. "Reparación de Pileta y Solárium").
     * @param descripcion Alcance técnico y plazos de la obra.
     * @param administradorOContratista Billetera responsable de recibir los fondos y rendir cuentas.
     * @param presupuestoTotal Costo total aprobado en Wei para los 3 hitos (100%).
     * @return obraId Identificador único asignado a la obra creada.
     */
    function aprobarObraYLiberarHito1(
        string calldata nombre,
        string calldata descripcion,
        address payable administradorOContratista,
        uint256 presupuestoTotal
    ) external onlyTimelock whenNotPaused nonReentrant returns (uint256 obraId) {
        obraId = _crearObraInterna(nombre, descripcion, administradorOContratista, presupuestoTotal);
        _liberarHito1Interno(obraId);
    }

    /**
     * @notice Variante en dos pasos: registra y reserva el presupuesto de la obra sin liberar aún el Hito 1.
     * @param nombre Título de la obra.
     * @param descripcion Alcance técnico y plazos de la obra.
     * @param administradorOContratista Billetera responsable de recibir los fondos y rendir cuentas.
     * @param presupuestoTotal Costo total aprobado en Wei para los 3 hitos (100%).
     * @return obraId Identificador único asignado a la obra creada.
     */
    function crearObra(
        string calldata nombre,
        string calldata descripcion,
        address payable administradorOContratista,
        uint256 presupuestoTotal
    ) external onlyTimelock whenNotPaused returns (uint256 obraId) {
        obraId = _crearObraInterna(nombre, descripcion, administradorOContratista, presupuestoTotal);
    }

    /**
     * @notice Libera el Hito 1 (30% - Anticipo/Materiales) si la obra fue creada previamente con `crearObra`.
     * @param obraId Identificador de la obra cuyo Hito 1 se desea liberar.
     */
    function liberarHito1(uint256 obraId) external onlyTimelock whenNotPaused nonReentrant {
        _validarObraExistente(obraId);
        _liberarHito1Interno(obraId);
    }

    // =========================================================================
    // 3. Rendición de Cuentas del Administrador (Requisito previo entre Hitos)
    // =========================================================================

    /**
     * @notice El Administrador carga en la blockchain el hash IPFS / enlace con facturas, remitos
     *         y fotos de avance del Hito 1 para habilitar el tratamiento y liberación del Hito 2.
     * @dev Cachea `administradorOContratista` y `estado` en variables locales para evitar lecturas repetidas de storage.
     * @param obraId Identificador de la obra.
     * @param comprobantesIpfsCid CID de IPFS o URI con la documentación respaldatoria del Hito 1.
     */
    function rendirCuentasHito1(
        uint256 obraId,
        string calldata comprobantesIpfsCid
    ) external whenNotPaused {
        _validarObraExistente(obraId);
        Obra storage obra = obras[obraId];
        address adminObra = obra.administradorOContratista;
        if (msg.sender != adminObra) {
            revert SoloAdministradorDeObra(msg.sender, adminObra);
        }

        EstadoObra estadoActual = obra.estado;
        if (estadoActual != EstadoObra.Hito1Liberado) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.Hito1Liberado);
        }
        if (bytes(comprobantesIpfsCid).length == 0) revert RendicionDeCuentasVacia();

        obra.rendicionHito1Cid = comprobantesIpfsCid;
        obra.estado = EstadoObra.Hito1Rendido;

        emit RendicionDeCuentasPresentada(obraId, 1, msg.sender, comprobantesIpfsCid);
    }

    /**
     * @notice El Administrador carga en la blockchain el hash IPFS / enlace con la rendición del
     *         Hito 2 (avance intermedio) para habilitar la votación de liquidación final (Hito 3).
     * @dev Cachea `administradorOContratista` y `estado` en variables locales para evitar lecturas repetidas de storage.
     * @param obraId Identificador de la obra.
     * @param comprobantesIpfsCid CID de IPFS o URI con la documentación respaldatoria del Hito 2.
     */
    function rendirCuentasHito2(
        uint256 obraId,
        string calldata comprobantesIpfsCid
    ) external whenNotPaused {
        _validarObraExistente(obraId);
        Obra storage obra = obras[obraId];
        address adminObra = obra.administradorOContratista;
        if (msg.sender != adminObra) {
            revert SoloAdministradorDeObra(msg.sender, adminObra);
        }

        EstadoObra estadoActual = obra.estado;
        if (estadoActual != EstadoObra.Hito2Liberado) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.Hito2Liberado);
        }
        if (bytes(comprobantesIpfsCid).length == 0) revert RendicionDeCuentasVacia();

        obra.rendicionHito2Cid = comprobantesIpfsCid;
        obra.estado = EstadoObra.Hito2Rendido;

        emit RendicionDeCuentasPresentada(obraId, 2, msg.sender, comprobantesIpfsCid);
    }

    // =========================================================================
    // 4. Liberación de Hito 2 (40%) e Hito 3 Final (30%) vía ConsorcioTimelock
    // =========================================================================

    /**
     * @notice Libera el Hito 2 (40% - Avance intermedio) tras la 2da votación del Consorcio.
     *         Falla automáticamente si el Administrador no rindió cuentas antes del Hito 1.
     * @dev Cumple estrictamente Checks-Effects-Interactions (CEI) emitiendo el evento antes de la llamada externa.
     *      Usa `unchecked` en la resta de `fondosComprometidosEnObras` ya que el 100% fue reservado al crear la obra.
     * @param obraId Identificador de la obra.
     */
    function liberarHito2(uint256 obraId) external onlyTimelock whenNotPaused nonReentrant {
        _validarObraExistente(obraId);
        Obra storage obra = obras[obraId];
        EstadoObra estadoActual = obra.estado;
        if (estadoActual != EstadoObra.Hito1Rendido) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.Hito1Rendido);
        }

        uint256 presupuesto = obra.presupuestoTotal;
        uint256 montoHito2 = (presupuesto * PORCENTAJE_HITO_2) / 100;
        uint256 nuevoAcumulado = obra.montoLiberado + montoHito2;
        address payable destinatario = obra.administradorOContratista;

        // Effects
        obra.estado = EstadoObra.Hito2Liberado;
        obra.montoLiberado = nuevoAcumulado;
        unchecked {
            // Seguro: `fondosComprometidosEnObras` reservó el 100% y solo se liberó el 30% en Hito 1.
            fondosComprometidosEnObras -= montoHito2;
        }

        emit HitoLiberado(obraId, 2, destinatario, montoHito2, nuevoAcumulado);

        // Interactions
        _transferirETH(destinatario, montoHito2);
    }

    /**
     * @notice Libera el Hito 3 (30% restante - Entrega final) tras la 3ra votación del Consorcio.
     *         Falla automáticamente si el Administrador no rindió cuentas antes del Hito 2.
     * @dev Cumple estrictamente Checks-Effects-Interactions (CEI).
     *      Usa `unchecked` porque `liberadoHastaAhora` es exactamente el 70% de `presupuesto`.
     * @param obraId Identificador de la obra.
     * @param actaEntregaFinalCid Hash IPFS opcional del acta de recepción definitiva de la obra.
     */
    function liberarHito3Final(
        uint256 obraId,
        string calldata actaEntregaFinalCid
    ) external onlyTimelock whenNotPaused nonReentrant {
        _validarObraExistente(obraId);
        Obra storage obra = obras[obraId];
        EstadoObra estadoActual = obra.estado;
        if (estadoActual != EstadoObra.Hito2Rendido) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.Hito2Rendido);
        }

        uint256 presupuesto = obra.presupuestoTotal;
        uint256 liberadoHastaAhora = obra.montoLiberado;
        address payable destinatario = obra.administradorOContratista;
        uint256 montoHito3;

        // Effects
        unchecked {
            // Seguro: `liberadoHastaAhora` acumula únicamente Hito 1 (30%) + Hito 2 (40%) = 70% <= presupuesto.
            montoHito3 = presupuesto - liberadoHastaAhora;
            fondosComprometidosEnObras -= montoHito3;
        }

        obra.estado = EstadoObra.Finalizada;
        obra.montoLiberado = presupuesto;
        obra.actaEntregaFinalCid = actaEntregaFinalCid;

        emit HitoLiberado(obraId, 3, destinatario, montoHito3, presupuesto);

        // Interactions
        _transferirETH(destinatario, montoHito3);
    }

    /**
     * @notice Permite al Consorcio cancelar una obra por incumplimiento mediante votación en el Governor,
     *         liberando el presupuesto remanente para que vuelva a estar disponible en el Vault.
     * @dev Intencionalmente sin `whenNotPaused` (hallazgo CD-09): cancelar una obra no transfiere ETH
     *      al exterior, sino que descompromete la reserva contable y actúa como herramienta de recuperación
     *      financiera incluso cuando el Vault se encuentra pausado por una contingencia.
     * @param obraId Identificador de la obra a cancelar.
     */
    function cancelarObra(uint256 obraId) external onlyTimelock {
        _validarObraExistente(obraId);
        Obra storage obra = obras[obraId];
        EstadoObra estadoActual = obra.estado;
        if (
            estadoActual == EstadoObra.Inexistente ||
            estadoActual == EstadoObra.Finalizada ||
            estadoActual == EstadoObra.Cancelada
        ) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.Hito1Liberado);
        }

        uint256 presupuesto = obra.presupuestoTotal;
        uint256 liberadoHastaAhora = obra.montoLiberado;
        uint256 saldoNoEjecutado;

        unchecked {
            // Seguro: una obra no finalizada siempre tiene `liberadoHastaAhora < presupuesto`.
            saldoNoEjecutado = presupuesto - liberadoHastaAhora;
            fondosComprometidosEnObras -= saldoNoEjecutado;
        }

        obra.estado = EstadoObra.Cancelada;

        emit ObraCancelada(obraId, saldoNoEjecutado);
    }

    // =========================================================================
    // 5. [CORRECCIÓN DOCENTE - PUNTO 2] Retiro Pull de Pagos en Custodia
    // =========================================================================

    /**
     * @notice Permite a un contratista retirar los fondos que quedaron en custodia Pull cuando su dirección
     *         rechazó la transferencia directa de ETH al liberarse un hito.
     * @dev [CORRECCIÓN DOCENTE - PUNTO 2] Aplica estrictamente Checks-Effects-Interactions (CEI) y `nonReentrant`.
     *      Permite indicar una dirección `receptor` (por ejemplo, una EOA operativa del contratista si el
     *      contratista registrado en la obra era un contrato inteligente sin función `receive()`).
     * @param receptor Dirección payable donde se acreditará el ETH retirado.
     */
    function retirarPagoContratista(address payable receptor) external nonReentrant {
        if (receptor == address(0) || receptor == address(this) || receptor == timelock) {
            revert DireccionInvalida();
        }

        uint256 monto = pagosPendientesContratista[msg.sender];
        if (monto == 0) revert SinPagosPendientes(msg.sender);

        // Effects
        pagosPendientesContratista[msg.sender] = 0;
        unchecked {
            // Seguro: `totalPagosPendientesContratistas` es la suma exacta de `pagosPendientesContratista`.
            totalPagosPendientesContratistas -= monto;
        }

        emit PagoContratistaRetirado(msg.sender, receptor, monto);

        // Interactions
        (bool exito, ) = receptor.call{value: monto}("");
        if (!exito) revert FalloTransferenciaETH();
    }

    // =========================================================================
    // Funciones de Consulta (Views & Pure)
    // =========================================================================

    /**
     * @notice Devuelve el saldo libre del Vault (descontando los fondos ya reservados para obras en curso
     *         y los pagos en custodia Pull pendientes de retiro por contratistas).
     * @return Saldo disponible en wei para comprometer en nuevas obras.
     */
    function saldoLibreDisponible() public view returns (uint256) {
        uint256 balanceActual = address(this).balance;
        uint256 comprometido = fondosComprometidosEnObras + totalPagosPendientesContratistas;
        if (balanceActual <= comprometido) return 0;
        unchecked {
            return balanceActual - comprometido;
        }
    }

    /**
     * @notice Calcula el desglose exacto de los 3 hitos (30%, 40%, 30%) para un presupuesto dado.
     * @param presupuestoTotal Monto total presupuestado en wei.
     * @return hito1 Monto correspondiente al Hito 1 (30%).
     * @return hito2 Monto correspondiente al Hito 2 (40%).
     * @return hito3 Monto correspondiente al Hito 3 (30% más residuo de redondeo).
     */
    function calcularDesgloseHitos(uint256 presupuestoTotal)
        external
        pure
        returns (uint256 hito1, uint256 hito2, uint256 hito3)
    {
        hito1 = (presupuestoTotal * PORCENTAJE_HITO_1) / 100;
        hito2 = (presupuestoTotal * PORCENTAJE_HITO_2) / 100;
        unchecked {
            // Seguro: 30% + 40% = 70% <= 100% de `presupuestoTotal`.
            hito3 = presupuestoTotal - hito1 - hito2;
        }
    }

    // =========================================================================
    // Funciones Internas
    // =========================================================================

    /**
     * @dev Verifica que el identificador `obraId` corresponda a una obra efectivamente registrada (`1 .. totalObras`).
     * @param obraId Identificador de la obra a validar.
     */
    function _validarObraExistente(uint256 obraId) internal view {
        if (obraId == 0 || obraId > totalObras) {
            revert ObraInexistente(obraId);
        }
    }

    /**
     * @dev Registra una nueva obra en storage y reserva el 100% de su presupuesto en `fondosComprometidosEnObras`.
     *      Valida que `administradorOContratista` no sea `address(0)`, `address(this)` ni `timelock`.
     * @param nombre Título de la obra.
     * @param descripcion Alcance técnico y plazos.
     * @param administradorOContratista Billetera responsable de la obra.
     * @param presupuestoTotal Presupuesto total aprobado en wei.
     * @return obraId Identificador único asignado a la obra.
     */
    function _crearObraInterna(
        string calldata nombre,
        string calldata descripcion,
        address payable administradorOContratista,
        uint256 presupuestoTotal
    ) internal returns (uint256 obraId) {
        if (
            administradorOContratista == address(0) ||
            administradorOContratista == address(this) ||
            administradorOContratista == timelock
        ) {
            revert DireccionInvalida();
        }
        if (presupuestoTotal == 0) revert MontoInvalido();

        uint256 disponible = saldoLibreDisponible();
        if (disponible < presupuestoTotal) {
            revert FondosInsuficientesEnVault(disponible, presupuestoTotal);
        }

        unchecked {
            // Seguro: un contador secuencial de obras jamás alcanzará 2^256 - 1.
            obraId = ++totalObras;
        }
        fondosComprometidosEnObras += presupuestoTotal;

        obras[obraId] = Obra({
            id: obraId,
            nombre: nombre,
            descripcion: descripcion,
            administradorOContratista: administradorOContratista,
            presupuestoTotal: presupuestoTotal,
            montoLiberado: 0,
            estado: EstadoObra.AprobadaPendienteHito1,
            rendicionHito1Cid: "",
            rendicionHito2Cid: "",
            actaEntregaFinalCid: ""
        });

        emit ObraCreada(obraId, nombre, administradorOContratista, presupuestoTotal);
    }

    /**
     * @dev Ejecuta la liberación del Hito 1 (30%) aplicando estrictamente Checks-Effects-Interactions.
     * @param obraId Identificador de la obra.
     */
    function _liberarHito1Interno(uint256 obraId) internal {
        Obra storage obra = obras[obraId];
        EstadoObra estadoActual = obra.estado;
        if (estadoActual != EstadoObra.AprobadaPendienteHito1) {
            revert EstadoDeObraInvalido(obraId, estadoActual, EstadoObra.AprobadaPendienteHito1);
        }

        uint256 presupuesto = obra.presupuestoTotal;
        uint256 montoHito1 = (presupuesto * PORCENTAJE_HITO_1) / 100;
        address payable destinatario = obra.administradorOContratista;

        // Effects
        obra.estado = EstadoObra.Hito1Liberado;
        obra.montoLiberado = montoHito1;
        unchecked {
            // Seguro: `fondosComprometidosEnObras` reservó el 100% del presupuesto al crearse la obra.
            fondosComprometidosEnObras -= montoHito1;
        }

        emit HitoLiberado(obraId, 1, destinatario, montoHito1, montoHito1);

        // Interactions
        _transferirETH(destinatario, montoHito1);
    }

    /**
     * @dev [CORRECCIÓN DOCENTE - PUNTO 2] Esquema Híbrido `Push + Pull Fallback` para liberación de fondos:
     *      Intenta transferir el ETH directamente al contratista mediante `.call{value: monto}("")`.
     *      Si el destinatario es un contrato inteligente que rechaza ETH (no tiene `receive()` payable o revierte),
     *      en lugar de revertir toda la ejecución del Timelock y bloquear el avance de la obra, acredita el
     *      importe en `pagosPendientesContratista[destinatario]` y `totalPagosPendientesContratistas`, emitiendo
     *      `PagoContratistaEnCustodia` para que el contratista pueda retirarlo luego vía `retirarPagoContratista`.
     * @param destinatario Dirección receptora del pago del hito.
     * @param monto Cantidad en wei a transferir o dejar en custodia Pull.
     */
    function _transferirETH(address payable destinatario, uint256 monto) internal {
        (bool exito, ) = destinatario.call{value: monto}("");
        if (!exito) {
            uint256 nuevoPendiente = pagosPendientesContratista[destinatario] + monto;
            pagosPendientesContratista[destinatario] = nuevoPendiente;
            totalPagosPendientesContratistas += monto;
            emit PagoContratistaEnCustodia(destinatario, monto, nuevoPendiente);
        }
    }
}
