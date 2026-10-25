# PoC de Auditoría — Harness de Invariantes Foundry

**Proyecto:** ADM-Consorcios (ConsorcioDAO) · **Auditoría:** ETH Kipu Nivel 2, unidades 16-18

Este harness valida las **interacciones entre los 4 contratos propios** con testing de
invariantes de Foundry. Los módulos de OpenZeppelin v5.1.0 se asumen auditados y quedan
fuera del alcance.

## Instalación

1. Copiar el archivo al repositorio del proyecto:

```bash
cp ConsorcioDAOInvariants.t.sol /workspace/ADM-Consorcios/test/
```

2. Verificar que `remappings.txt` contiene:

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

3. Configuración recomendada en `foundry.toml`:

```toml
[invariant]
runs = 256
depth = 64
fail_on_revert = false   # los act del handler reintentan otras rutas al revertir
```

## Ejecución

```bash
# Suite completa (invariantes + tests de interacción)
forge test --match-contract ConsorcioDAOInvariants -vvv

# Solo los invariantes de fuzzing
forge test --match-test invariant_ -vvv

# Con reporte de cobertura del proyecto
forge coverage --no-match-coverage "(script|lib)"
```

## Invariantes verificados

| ID | Invariante | Función | Protege contra |
|----|------------|---------|----------------|
| I1 | `balance(vault) >= fondosComprometidosEnObras` (siempre) | `invariant_SolvenciaDelVault` | Extracción no respaldada de fondos |
| I2 | Contabilidad espejo (ghost) == storage real | `invariant_ContabilidadEspejo` | Desvíos contables en reservas de obras |
| I3 | `montoLiberado <= presupuestoTotal` en toda obra | `invariant_LiberadoNoSuperaPresupuesto` | Doble pago de hitos / desbordes de la máquina 30-40-30 |
| I4 | Soulbound: transferencias entre particulares revierten | `invariant_TransferenciasSiguenDeshabilitadas` + `act_transferenciaSoulbound` | Captura de gobernanza por compra de votos |
| I5 | Solo el Timelock logra liberar hitos (bajo fuzzing) | `act_intentoNoAutorizado` + `test_SoloTimelockLiberarHitos` | Bypass del control de acceso `onlyTimelock` |

## Tests de interacción de punta a punta

- `test_FlujoCompleto_Governor_Timelock_Obras`: propone una obra, vota, encola,
  ejecuta tras el `minDelay` y verifica la liberación del Hito 1 (30%) y la
  contabilidad del vault.
- `test_CD04_ExpensasSobreUnidadInexistente`: reproduce el hallazgo CD-04
  (`pagarExpensas` acredita unidades jamás adjudicadas).
- `test_SelladoRevocaAdminYBloqueaReejecucion`: verifica el sellado atómico del
  Timelock (CD-02: desplegar con `proposers=[]` y `executors=[]`).

## Portabilidad a Echidna

Las mismas propiedades se portan 1:1 a Echidna reemplazando `invariant_*` por
funciones `echidna_*` que devuelven `bool` (p. ej.
`function echidna_solvencia() public view returns (bool) { return address(obras).balance >= obras.fondosComprometidosEnObras(); }`)
y el handler por una herencia directa del harness. Los act del handler pasan a ser
funciones `public` invocables por el fuzzer.
