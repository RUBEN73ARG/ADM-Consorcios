// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC721Votes} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Votes.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title ConsorcioVotes
 * @author Equipo ConsorcioDAO - ETH Kipu Nivel 2
 * @notice Token ERC-721 (NFT Soulbound) de gobernanza que representa cada unidad funcional
 *         o lote dentro del Consorcio / Country y otorga derecho a voto atómico en asambleas.
 * @dev Basado en ERC721Votes y Ownable2Step de OpenZeppelin v5:
 *      https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Votes.sol
 *      Cada `unidadId` (ej. Lote 101) se representa como el `tokenId` del NFT, garantizando
 *      una relación 1:1 nativa con el inmueble físico, eliminando riesgos de préstamos flash
 *      (flash loans) sobre suministros fungibles y optimizando ~30% el consumo de gas al
 *      prescindir de quemado + re-emisión (`_burn` + `_mint`) en compraventas de unidades.
 *      Por defecto es intransferible entre particulares (Soulbound).
 *
 *      [CORRECCIÓN DOCENTE - PUNTO 6: Doble vía Registral + Timelock (`onlyRegistradorOrOwner`)]:
 *      Se incorpora la figura del `registrador` (Administrador Registral) junto al `owner` (`ConsorcioTimelock`).
 *      Esto permite que el alta de unidades (`adjudicarUnidad`) y el recupero de billetera o compraventa
 *      escriturada (`reasignarUnidad`) puedan ejecutarse en 1 paso por el Administrador Registral sin
 *      bloquear operativamente al consorcio (evitando un deadlock de quórum si varios vecinos pierden
 *      sus billeteras), mientras que el `ConsorcioTimelock` (`owner` vía `Ownable2Step`) conserva la
 *      soberanía suprema para ejecutar reasignaciones por asamblea o reemplazar/revocar al `registrador`.
 */
contract ConsorcioVotes is ERC721, EIP712, ERC721Votes, Ownable2Step {
    // =========================================================================
    // Variables de Estado
    // =========================================================================

    /// @notice Indica si las transferencias libres entre vecinos están habilitadas (`false` por defecto).
    bool public transferenciasHabilitadas;

    /// @dev Flag transitorio interno para autorizar transferencias ejecutadas por `reasignarUnidad`.
    bool private _reasignacionAutorizada;

    /// @notice Dirección del Administrador Registral autorizado a adjudicar y reasignar unidades en 1 paso (Corrección Docente Punto 6).
    address public registrador;

    /// @notice Registro de la alícuota / cuota parte informativa asignada a cada unidad funcional / lote.
    mapping(uint256 unidadId => uint256 cuotaParte) public cuotaParteDeUnidad;

    // =========================================================================
    // Errores Personalizados (Custom Errors)
    // =========================================================================

    /// @notice Se lanza cuando un vecino intenta transferir su NFT de unidad estando deshabilitadas las transferencias.
    error TokenIntransferibleEntreParticulares();

    /// @notice Se lanza cuando se proporciona la dirección cero (`address(0)`) como destinatario o propietario.
    error DireccionInvalida();

    /// @notice Se lanza cuando se intenta adjudicar una unidad funcional con cuota parte igual a cero.
    error CuotaParteInvalida();

    /// @notice Se lanza cuando se intenta adjudicar una unidad funcional que ya tiene un propietario registrado.
    /// @param unidadId Identificador de la unidad funcional o lote (`tokenId`).
    /// @param propietarioActual Dirección del propietario ya registrado para dicha unidad.
    error UnidadYaAsignada(uint256 unidadId, address propietarioActual);

    /// @notice Se lanza cuando una cuenta sin rol de `registrador` ni `owner` (Timelock) intenta gestionar unidades (Corrección Docente Punto 6).
    /// @param cuenta Dirección que intentó ejecutar la operación sin autorización.
    error NoAutorizadoParaRegistro(address cuenta);

    // =========================================================================
    // Eventos
    // =========================================================================

    /// @notice Se emite cuando se adjudica una unidad funcional (NFT) a un propietario y se activa su voto.
    /// @param unidadId Identificador único de la unidad funcional o lote (`tokenId`).
    /// @param propietario Billetera del vecino propietario.
    /// @param cuotaParte Alícuota / referencia de cuota parte registrada para la unidad.
    event UnidadAdjudicada(uint256 indexed unidadId, address indexed propietario, uint256 cuotaParte);

    /// @notice Se emite cuando el consorcio reasigna una unidad funcional a un nuevo propietario por compraventa o recupero.
    /// @param unidadId Identificador de la unidad funcional o lote transferido (`tokenId`).
    /// @param propietarioAnterior Billetera del propietario saliente.
    /// @param nuevoPropietario Billetera del nuevo propietario entrante.
    /// @param cuotaParte Alícuota / cuota parte asociada a la unidad transferida.
    event UnidadTransferidaPorConsorcio(
        uint256 indexed unidadId,
        address indexed propietarioAnterior,
        address indexed nuevoPropietario,
        uint256 cuotaParte
    );

    /// @notice Se emite cuando se modifica la política de transferibilidad del NFT de gobernanza.
    /// @param habilitadas Nuevo estado de las transferencias entre particulares (`true` o `false`).
    event EstadoTransferenciasActualizado(bool habilitadas);

    /// @notice Se emite cuando el Owner/Timelock actualiza la dirección del Administrador Registral (Corrección Docente Punto 6).
    /// @param registradorAnterior Dirección del registrador saliente.
    /// @param nuevoRegistrador Dirección del nuevo registrador designado.
    event RegistradorActualizado(address indexed registradorAnterior, address indexed nuevoRegistrador);

    // =========================================================================
    // Modificadores
    // =========================================================================

    /**
     * @notice Permite la ejecución tanto al Administrador Registral (`registrador`) para agilidad operativa
     *         como al `owner` supremo del contrato (`ConsorcioTimelock`) por decisión de Asamblea.
     * @dev Implementa la Corrección del Docente (Punto 6) evitando deadlocks de quórum ante pérdida de billeteras.
     */
    modifier onlyRegistradorOrOwner() {
        if (msg.sender != registrador && msg.sender != owner()) {
            revert NoAutorizadoParaRegistro(msg.sender);
        }
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Inicializa la colección NFT de Unidades Funcionales con transferencias entre particulares deshabilitadas.
     * @param initialOwner Dirección inicial de administración y registrador inicial (luego el ownership se transfiere al `ConsorcioTimelock`).
     */
    constructor(address initialOwner)
        ERC721("Consorcio Unidad Funcional", "CUF")
        EIP712("Consorcio Unidad Funcional", "1")
        Ownable(initialOwner)
    {
        transferenciasHabilitadas = false;
        registrador = initialOwner;
        emit RegistradorActualizado(address(0), initialOwner);
    }

    // =========================================================================
    // Funciones Externas de Administración y Registro
    // =========================================================================

    /**
     * @notice Permite al Owner (`ConsorcioTimelock`) designar o revocar al Administrador Registral (`address(0)` para deshabilitarlo).
     * @dev Corrección Docente Punto 6: La Asamblea a través del Timelock conserva siempre el control supremo sobre quién opera el padrón.
     * @param nuevoRegistrador Nueva dirección autorizada como registrador operativo (o `address(0)` para dejar solo al Timelock).
     */
    function actualizarRegistrador(address nuevoRegistrador) external onlyOwner {
        address anterior = registrador;
        registrador = nuevoRegistrador;
        emit RegistradorActualizado(anterior, nuevoRegistrador);
    }

    /**
     * @notice Adjudica una unidad funcional/lote a un vecino emitiendo su NFT (`tokenId = unidadId`).
     * @dev Auto-delega el poder de voto al propio vecino para que pueda votar inmediatamente
     *      sin necesidad de ejecutar una transacción adicional de `delegate()`.
     *      Consulta `_ownerOf(unidadId)` en memoria para evitar doble lectura de storage (`SLOAD`).
     *      Ejecutable por el `registrador` o por el `owner` (`ConsorcioTimelock`).
     * @param unidadId Identificador único del departamento o lote (ej. Lote 101 o UF 42), usado como `tokenId`.
     * @param vecino Billetera del propietario del lote/departamento.
     * @param cuotaParte Valor de alícuota o referencia de expensas asociado a la unidad (debe ser > 0).
     */
    function adjudicarUnidad(
        uint256 unidadId,
        address vecino,
        uint256 cuotaParte
    ) external onlyRegistradorOrOwner {
        if (vecino == address(0)) revert DireccionInvalida();
        if (cuotaParte == 0) revert CuotaParteInvalida();

        address propietarioActual = _ownerOf(unidadId);
        if (propietarioActual != address(0)) {
            revert UnidadYaAsignada(unidadId, propietarioActual);
        }

        cuotaParteDeUnidad[unidadId] = cuotaParte;
        _mint(vecino, unidadId);

        // Auto-delegación inicial si el vecino aún no tiene delegatario asignado
        if (delegates(vecino) == address(0)) {
            _delegate(vecino, vecino);
        }

        emit UnidadAdjudicada(unidadId, vecino, cuotaParte);
    }

    /**
     * @notice Reasigna la titularidad del NFT de una unidad funcional cuando cambia de dueño o por recupero de billetera.
     * @dev Transfiere directamente el `tokenId = unidadId` mediante `_update` autorizando temporalmente
     *      la operación con `_reasignacionAutorizada`, evitando el sobrecosto de gas de `_burn` + `_mint`
     *      y manteniendo intactas las demás unidades que posea el mismo propietario.
     *      Ejecutable por el `registrador` (tras verificar escritura o identidad off-chain) o por el `owner` (`ConsorcioTimelock`).
     * @param unidadId Identificador del lote o departamento (`tokenId`).
     * @param nuevoPropietario Billetera del comprador o nueva billetera de recupero del copropietario.
     */
    function reasignarUnidad(uint256 unidadId, address nuevoPropietario) external onlyRegistradorOrOwner {
        address propietarioAnterior = _ownerOf(unidadId);
        if (propietarioAnterior == address(0) || nuevoPropietario == address(0)) {
            revert DireccionInvalida();
        }

        uint256 cuotaUnidad = cuotaParteDeUnidad[unidadId];

        _reasignacionAutorizada = true;
        _update(nuevoPropietario, unidadId, address(0));
        _reasignacionAutorizada = false;

        if (delegates(nuevoPropietario) == address(0)) {
            _delegate(nuevoPropietario, nuevoPropietario);
        }

        emit UnidadTransferidaPorConsorcio(unidadId, propietarioAnterior, nuevoPropietario, cuotaUnidad);
    }

    /**
     * @notice Permite habilitar o deshabilitar transferencias si el estatuto del consorcio se modifica.
     * @param habilitadas `true` para permitir transferencias entre particulares, `false` para mantenerlo Soulbound.
     */
    function configurarTransferencias(bool habilitadas) external onlyOwner {
        transferenciasHabilitadas = habilitadas;
        emit EstadoTransferenciasActualizado(habilitadas);
    }

    // =========================================================================
    // Funciones de Consulta (View)
    // =========================================================================

    /**
     * @notice Devuelve la billetera propietaria registrada de una unidad funcional (`address(0)` si no fue adjudicada).
     * @dev Utiliza `_ownerOf(unidadId)` nativo de ERC-721 sin revertir si el token aún no existe.
     * @param unidadId Identificador de la unidad funcional o lote (`tokenId`).
     * @return propietario Dirección del titular actual de la unidad funcional.
     */
    function propietarioDeUnidad(uint256 unidadId) external view returns (address propietario) {
        return _ownerOf(unidadId);
    }

    // =========================================================================
    // Funciones Públicas y Overrides (EIP-6372 & OpenZeppelin v5)
    // =========================================================================

    /**
     * @notice Devuelve el reloj actual basado en timestamp del bloque según EIP-6372.
     * @return Timestamp actual truncado a `uint48`.
     */
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @notice Describe el modo de reloj utilizado por este token de gobernanza según EIP-6372.
     * @return Cadena estándar indicando modo timestamp.
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Hook central de OpenZeppelin v5 (`_update`) para ERC-721 y ERC721Votes.
     *      Bloquea las transferencias entre cuentas particulares cuando `transferenciasHabilitadas == false`
     *      y no se trata de una reasignación oficial del consorcio (`!_reasignacionAutorizada`).
     * @param to Dirección de destino (`address(0)` en burn).
     * @param tokenId Identificador del NFT (`unidadId`).
     * @param auth Dirección que autoriza la operación.
     * @return from Dirección del propietario anterior (`address(0)` en mint).
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Votes) returns (address from) {
        from = _ownerOf(tokenId);
        if (!transferenciasHabilitadas && !_reasignacionAutorizada && from != address(0) && to != address(0)) {
            revert TokenIntransferibleEntreParticulares();
        }
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Override requerido por Solidity para sincronizar incrementos de balance entre `ERC721` y `ERC721Votes`.
     * @param account Cuenta cuyo balance se incrementa.
     * @param value Cantidad de unidades incrementadas.
     */
    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Votes) {
        super._increaseBalance(account, value);
    }
}
