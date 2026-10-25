import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import {
  SEPOLIA_CHAIN_ID,
  CONTRACT_ADDRESSES,
  ETHERSCAN_BASE_URL,
  ESTADO_OBRA_NOMBRES,
  ESTADO_PROPUESTA_NOMBRES,
  PINATA_GATEWAY_URL,
  DEFAULT_PINATA_JWT,
} from './config.js';

import VotesArtifact from './abi/ConsorcioVotes.json';
import TimelockArtifact from './abi/ConsorcioTimelock.json';
import GovernorArtifact from './abi/ConsorcioGovernor.json';
import ObrasArtifact from './abi/ConsorcioObras.json';

const VotesAbi = VotesArtifact.abi || VotesArtifact;
const TimelockAbi = TimelockArtifact.abi || TimelockArtifact;
const GovernorAbi = GovernorArtifact.abi || GovernorArtifact;
const ObrasAbi = ObrasArtifact.abi || ObrasArtifact;

const VotesBytecode = VotesArtifact.bytecode?.object || VotesArtifact.bytecode || '';
const TimelockBytecode = TimelockArtifact.bytecode?.object || TimelockArtifact.bytecode || '';
const GovernorBytecode = GovernorArtifact.bytecode?.object || GovernorArtifact.bytecode || '';
const ObrasBytecode = ObrasArtifact.bytecode?.object || ObrasArtifact.bytecode || '';

// Billeteras determinísticas de Unidades Funcionales para pruebas en VS Code (Sin exponer datos personales - Caso 4)
const ACTORES_FOUNDRY = {
  alice: {
    nombre: '🏢 Titular UF 101 / 102',
    uf: 101,
    cuota: 100,
    address: '0x3b9DE69C652f54582155372d45bB176e810eEEA1',
  },
  bob: {
    nombre: '🏢 Billetera Secundaria UF 102',
    uf: 102,
    cuota: 100,
    address: '0x85E4E16Bd367E4259537269633DA9a6Aa4cf95a3',
    pk: '0x0000000000000000000000000000000000000000000000000000000000000102',
  },
  carlos: {
    nombre: '🏢 Titular UF 103',
    uf: 103,
    cuota: 100,
    address: '0xe6eF3a317f91A0a44eB097c8e68B49CcF9E63895',
    pk: '0x0000000000000000000000000000000000000000000000000000000000000103',
  },
  diana: {
    nombre: '🏢 Titular UF 104',
    uf: 104,
    cuota: 100,
    address: '0x3d67BC03e6E562079BfC96Dd2bb52e6D7B78CafC',
    pk: '0x0000000000000000000000000000000000000000000000000000000000000104',
  },
  dianaRecupero: {
    nombre: '🔄 Billetera Recupero UF 104',
    uf: 104,
    cuota: 100,
    address: '0x24d8C8008554f5EF8CA7F478592348b9c18c3507',
    pk: '0x0000000000000000000000000000000000000000000000000000000000000204',
  },
  inquilinoLeo: {
    nombre: '🔑 Locatario / Delegatario UF 102',
    uf: 102,
    cuota: 0,
    address: '0x64c8Ce16C52CD01b85Ff4d7e3b8F1855c1d80f0b',
    pk: '0x0000000000000000000000000000000000000000000000000000000000000302',
  },
};

function getActorLabel(addr) {
  if (!addr) return null;
  const lower = addr.toLowerCase();
  for (const key of Object.keys(ACTORES_FOUNDRY)) {
    if (ACTORES_FOUNDRY[key].address.toLowerCase() === lower) {
      return ACTORES_FOUNDRY[key].nombre;
    }
  }
  return null;
}

// Decodificador de Errores Personalizados de Solidity (Custom Errors V2)
function parseContractError(err) {
  const interfaces = [
    new ethers.Interface(GovernorAbi),
    new ethers.Interface(ObrasAbi),
    new ethers.Interface(VotesAbi),
    new ethers.Interface(TimelockAbi),
  ];

  const errorData = err?.data || err?.error?.data || err?.info?.error?.data;
  if (errorData && typeof errorData === 'string') {
    for (const iface of interfaces) {
      try {
        const parsed = iface.parseError(errorData);
        if (parsed) {
          if (parsed.name === 'GovernorUnexpectedProposalState') {
            const current = Number(parsed.args[1]);
            if (current === 0) return '⏳ TIEMPO DE ESPERA: La propuesta aún está en deliberación previa (Pending). Espera a que abra la votación.';
            if (current === 3) return '⌛ TIEMPO VENCIDO (TIMEOUT): La asamblea de votación finalizó o no alcanzó el quórum del 50%.';
            return `⚠️ Estado de propuesta no apto para esta acción: ${ESTADO_PROPUESTA_NOMBRES[current] || current}.`;
          }
          if (parsed.name === 'GovernorNonexistentProposal') return '❌ Propuesta no encontrada en este contrato.';
          if (parsed.name === 'GovernorAlreadyCastVote') return '⚠️ Esta billetera ya emitió su voto en esta propuesta.';
          if (parsed.name === 'GovernorInvalidSignature') return '❌ Firma EIP-712 inválida o el nonce del votante no coincide.';
          if (parsed.name === 'PropuestaNoEncolada') return '⚠️ [Corrección Docente Punto 5] Solo se puede cancelar con esta función una propuesta que esté en estado Queued (Encolada en el Timelock).';
          if (parsed.name === 'NoAutorizadoParaCancelar') return '🔒 [Corrección Docente Punto 5] Solo el Guardián (Síndico) o el Proponente original pueden cancelar una propuesta en cola.';
          if (parsed.name === 'QuorumInvalido') return `⚠️ [Corrección Docente Punto 1] El porcentaje de quórum debe estar entre 30% y 100% (Recibido: ${parsed.args[0]}%).`;
          if (parsed.name === 'UnidadNoAdjudicada') return `🚫 [Corrección Docente Punto 3] La Unidad Funcional #${parsed.args[0]} no está adjudicada en ConsorcioVotes (propietario == address(0)). Adjudícala primero antes de abonar expensas.`;
          if (parsed.name === 'SinPagosPendientes') return `ℹ️ [Corrección Docente Punto 2] La billetera ${parsed.args[0]} no tiene pagos pendientes en custodia Pull para retirar.`;
          if (parsed.name === 'NoAutorizadoParaRegistro') return `🔒 [Corrección Docente Punto 6] Solo el Administrador Registral o el Timelock (Owner) pueden adjudicar o reasignar unidades.`;
          if (parsed.name === 'ObraInexistente') return '❌ Obra no registrada en el consorcio.';
          if (parsed.name === 'SoloTimelockAutorizado') return '🔒 Acción reservada exclusivamente al Timelock descentralizado.';
          if (parsed.name === 'SoloAdministradorDeObra') return '👤 Solo el contratista/administrador asignado puede rendir cuentas.';
          if (parsed.name === 'AccessControlUnauthorizedAccount') return '🛡️ Falta otorgar roles en Timelock (AccessControl): Ejecuta el sellado de gobernanza primero.';
          if (parsed.name === 'TimelockUnexpectedOperationState') return '⏳ TIEMPO DE ESPERA EN CURSO: El retardo de seguridad del Timelock (60 segundos) aún no se cumplió o la operación fue cancelada.';
          if (parsed.name === 'UnidadYaAsignada') {
            return `⚠️ La Unidad Funcional #${parsed.args[0]} ya está adjudicada al propietario ${parsed.args[1]}. Si necesitas cambiar de billetera por venta o extravío, utiliza el panel de "Reasignar Unidad (Caso 2)".`;
          }
          if (parsed.name === 'TokenIntransferibleEntreParticulares') {
            return '🔒 NFT Soulbound: Las unidades funcionales son intransferibles entre particulares. Solo la administración o el Timelock pueden reasignarlas mediante reasignarUnidad.';
          }
          if (parsed.name === 'CuotaParteInvalida') return '⚠️ La cuota parte / alícuota debe ser mayor a 0.';
          if (parsed.name === 'DireccionInvalida') return '⚠️ Dirección de billetera inválida o la unidad aún no tiene propietario asignado.';
          if (parsed.name === 'OwnableUnauthorizedAccount') {
            return '🔒 Solo el Owner de ConsorcioVotes (Timelock) puede ejecutar esta acción.';
          }
          if (parsed.name === 'EstadoDeObraInvalido') {
            const actual = Number(parsed.args[1]);
            const requerido = Number(parsed.args[2]);
            const actualNombre = ESTADO_OBRA_NOMBRES[actual] || actual;
            const requeridoNombre = ESTADO_OBRA_NOMBRES[requerido] || requerido;
            return `⚠️ Regla de Seguridad Contable: La Obra está en "${actualNombre}". No puedes ejecutar esta etapa hasta que se encuentre en "${requeridoNombre}".`;
          }
          return `Error del Contrato (${parsed.name})`;
        }
      } catch (_) {}
    }
  }
  return err.reason || err.shortMessage || err.message || 'Error desconocido';
}

export default function App() {
  const [account, setAccount] = useState('');
  const [chainId, setChainId] = useState('');
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState({ text: '', type: 'info' });
  const [activeTab, setActiveTab] = useState('obras');

  // Direcciones activas de los 4 contratos V2 verificados en Sepolia
  const activeAddresses = CONTRACT_ADDRESSES;
  const setActiveAddresses = () => {};

  // Registro oficial de Logs de Despliegue e Interacciones en Sepolia
  const [txLogs, setTxLogs] = useState(() => {
    try {
      const saved = localStorage.getItem('consorcio_v2_tx_logs');
      return saved ? JSON.parse(saved) : [];
    } catch (_) {
      return [];
    }
  });

  function appendTxLog(entry) {
    setTxLogs((prev) => {
      const next = [
        {
          timestamp: new Date().toISOString(),
          ...entry,
        },
        ...prev,
      ];
      try {
        localStorage.setItem('consorcio_v2_tx_logs', JSON.stringify(next));
      } catch (_) {}
      return next;
    });
  }

  function updateContractAddress(key, addr) {
    setActiveAddresses((prev) => {
      const next = { ...prev, [key]: addr };
      try {
        localStorage.setItem('consorcio_v2_addresses', JSON.stringify(next));
      } catch (_) {}
      return next;
    });
  }

  // Bridge automático Foundry (VS Code) <-> MetaMask (Navegador)
  useEffect(() => {
    let active = true;
    let busy = false;
    const timer = setInterval(async () => {
      if (!active || busy || !window.ethereum) return;
      try {
        const res = await fetch('/rpc-pending-v2');
        if (!res.ok) return;
        const data = await res.json();
        if (!data || !data.pending) return;
        busy = true;
        const { queueId, tx } = data.pending;
        try {
          const cleanTx = {
            from: tx.from,
            data: tx.data || tx.input || '0x',
          };
          if (tx.to) cleanTx.to = tx.to;
          if (tx.value && tx.value !== '0x0' && tx.value !== '0x') cleanTx.value = tx.value;
          if (tx.gas) cleanTx.gas = tx.gas;

          const targetLabel = tx.to ? `${tx.to.slice(0, 6)}...${tx.to.slice(-4)}` : 'Deploy Contrato';
          setStatus({
            type: 'info',
            text: `🦊 Foundry (VS Code) solicita firma en MetaMask (Tx #${queueId} -> ${targetLabel}). Por favor confirma en la ventana de MetaMask...`,
          });

          await window.ethereum.request({ method: 'eth_requestAccounts' });
          const txHash = await window.ethereum.request({
            method: 'eth_sendTransaction',
            params: [cleanTx],
          });

          setStatus({
            type: 'success',
            text: `✅ Transacción #${queueId} firmada en MetaMask y enviada a Foundry: ${txHash}`,
          });

          await fetch('/rpc-result-v2', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ queueId, result: txHash }),
          });
        } catch (err) {
          setStatus({
            type: 'error',
            text: `Error al firmar en MetaMask: ${err?.message || String(err)}`,
          });
          await fetch('/rpc-result-v2', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ queueId, error: err?.message || String(err) }),
          });
        } finally {
          busy = false;
        }
      } catch (_) {
        busy = false;
      }
    }, 800);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, []);

  // Métricas del protocolo
  const [vaultBalance, setVaultBalance] = useState('0');
  const [fondosComprometidos, setFondosComprometidos] = useState('0');
  const [saldoLibre, setSaldoLibre] = useState('0');
  const [totalPagosPull, setTotalPagosPull] = useState('0');
  const [miPagoPullPendiente, setMiPagoPullPendiente] = useState('0');
  const [pullReceptorAddr, setPullReceptorAddr] = useState('');

  const [userVotes, setUserVotes] = useState('0');
  const [userNftBalance, setUserNftBalance] = useState('0');
  const [userDelegatee, setUserDelegatee] = useState(ethers.ZeroAddress);
  const [votesOwner, setVotesOwner] = useState(ethers.ZeroAddress);
  const [votesRegistrador, setVotesRegistrador] = useState(ethers.ZeroAddress);
  const [governorGuardian, setGovernorGuardian] = useState(ethers.ZeroAddress);
  const [governorQuorumPct, setGovernorQuorumPct] = useState('50');

  const [obrasList, setObrasList] = useState([]);
  const [proposalStateInfo, setProposalStateInfo] = useState(null);
  const [timelockSellado, setTimelockSellado] = useState(false);

  // Padrón de Unidades Funcionales (Casos 1, 2, 3 y 4)
  const [trackedUnitIds, setTrackedUnitIds] = useState([101, 102, 103, 104]);
  const [customUnitSearch, setCustomUnitSearch] = useState('');
  const [unidadesInfo, setUnidadesInfo] = useState([]);

  // Caso 1: Alta de Nuevo Propietario (adjudicarUnidad)
  const [altaUnidadId, setAltaUnidadId] = useState('101');
  const [altaVecinoAddr, setAltaVecinoAddr] = useState('0x3b9DE69C652f54582155372d45bB176e810eEEA1');
  const [altaCuotaParte, setAltaCuotaParte] = useState('100');

  // Caso 2: Recupero de Billetera / Venta de Lote (reasignarUnidad)
  const [reasigUnidadId, setReasigUnidadId] = useState('104');
  const [reasigNuevaAddr, setReasigNuevaAddr] = useState('');
  const [reasigDniEmail, setReasigDniEmail] = useState('');

  // Caso 3: Pago de Expensas (Inquilino o Propietario)
  const [pagoUnidadId, setPagoUnidadId] = useState('101');
  const [pagoMonto, setPagoMonto] = useState('0.001');
  const [pagoConcepto, setPagoConcepto] = useState('');
  const [pagoUnidadDetalle, setPagoUnidadDetalle] = useState(null);

  // Caso 4: Delegación de Voto a Inquilino (delegate)
  const [delegateTargetAddr, setDelegateTargetAddr] = useState('');

  // Caso 5: Votación Gasless por Firma EIP-712 (castVoteBySig)
  const [sigData, setSigData] = useState(null);
  const [manualSigProposalId, setManualSigProposalId] = useState('');
  const [manualSigSupport, setManualSigSupport] = useState('1');
  const [manualSigVoter, setManualSigVoter] = useState('');
  const [manualSigHex, setManualSigHex] = useState('');

  // Gobernanza y Obras
  const [propTipo, setPropTipo] = useState('nuevaObra');
  const [propObraId, setPropObraId] = useState('1');
  const [propActiveData, setPropActiveData] = useState(() => {
    try {
      const s = localStorage.getItem('last_proposal_data');
      return s ? JSON.parse(s) : null;
    } catch (_) { return null; }
  });

  const [propNombre, setPropNombre] = useState('Reparacion de Luminarias y Acceso Principal');
  const [propDesc, setPropDesc] = useState('Recambio de reflectores LED perimetrales y barrera automatica (Hitos 30/40/30)');
  const [propContratista, setPropContratista] = useState('0x3b9DE69C652f54582155372d45bB176e810eEEA1');
  const [propPresupuesto, setPropPresupuesto] = useState('0.0005');
  const [propIdVote, setPropIdVote] = useState('14482728348493155502191935859541702641564493741427847260982949677415526180625');
  const [voteSupport, setVoteSupport] = useState('1');

  const [rendicionObraId, setRendicionObraId] = useState('1');
  const [rendicionHitoNum, setRendicionHitoNum] = useState('1');
  const [rendicionCid, setRendicionCid] = useState('ipfs://QmbfbLn2ddGEG3dvFfCMGrbJR9iE5AZixHe6sU7Q6WXhfw');
  const [uploadingIpfs, setUploadingIpfs] = useState(false);
  const [uploadedFileInfo, setUploadedFileInfo] = useState(null);

  // Conexión Web3
  async function connectWallet() {
    if (!window.ethereum) {
      alert('MetaMask u otra billetera compatible con EIP-1193 no detectada. Por favor instala MetaMask.');
      return;
    }
    try {
      setLoading(true);
      const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
      const currentChainId = await window.ethereum.request({ method: 'eth_chainId' });
      setAccount(accounts[0]);
      setChainId(currentChainId);

      if (currentChainId !== SEPOLIA_CHAIN_ID) {
        await switchNetwork();
      }
      setStatus({ text: 'Billetera MetaMask conectada exitosamente.', type: 'success' });
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al conectar billetera: ' + (err.message || err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function switchNetwork() {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: SEPOLIA_CHAIN_ID }],
      });
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Por favor cambia la red de tu billetera a Sepolia Testnet.', type: 'warning' });
    }
  }

  // ===========================================================================
  // ETAPA 4: DESPLIEGUE CANÓNICO V2 EN SEPOLIA DESDE METAMASK (PASO A PASO)
  // ===========================================================================
  async function handleDeployVotesV2() {
    if (!account) return alert('Conecta tu billetera MetaMask primero.');
    try {
      setLoading(true);
      setStatus({ text: 'Paso 1/5: Firma en MetaMask el despliegue de ConsorcioVotes V2...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const factory = new ethers.ContractFactory(VotesAbi, VotesBytecode, signer);
      const contract = await factory.deploy(account);
      const deployTx = contract.deploymentTransaction();
      setStatus({ text: `Desplegando ConsorcioVotes V2 (Tx: ${deployTx.hash})... Esperando confirmación en Sepolia...`, type: 'info' });
      const receipt = await deployTx.wait();
      const deployedAddr = await contract.getAddress();

      updateContractAddress('ConsorcioVotes', deployedAddr);
      appendTxLog({
        accion: '1. Deploy ConsorcioVotes V2',
        contrato: 'ConsorcioVotes',
        address: deployedAddr,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `initialOwner = ${account}`,
      });

      setStatus({ text: `✅ ConsorcioVotes V2 desplegado en ${deployedAddr} (Tx: ${receipt.hash})`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al desplegar ConsorcioVotes V2: ' + parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function handleDeployTimelockV2() {
    if (!account) return alert('Conecta tu billetera MetaMask primero.');
    try {
      setLoading(true);
      setStatus({ text: 'Paso 2/5: Firma en MetaMask el despliegue de ConsorcioTimelock V2 (minDelay=60s)...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const factory = new ethers.ContractFactory(TimelockAbi, TimelockBytecode, signer);
      const contract = await factory.deploy(60, [], [], account);
      const deployTx = contract.deploymentTransaction();
      setStatus({ text: `Desplegando ConsorcioTimelock V2 (Tx: ${deployTx.hash})... Esperando confirmación...`, type: 'info' });
      const receipt = await deployTx.wait();
      const deployedAddr = await contract.getAddress();

      updateContractAddress('ConsorcioTimelock', deployedAddr);
      appendTxLog({
        accion: '2. Deploy ConsorcioTimelock V2',
        contrato: 'ConsorcioTimelock',
        address: deployedAddr,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `minDelay = 60, proposers = [], executors = [], admin = ${account}`,
      });

      setStatus({ text: `✅ ConsorcioTimelock V2 desplegado en ${deployedAddr} (Tx: ${receipt.hash})`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al desplegar ConsorcioTimelock V2: ' + parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function handleDeployGovernorV2() {
    if (!account) return alert('Conecta tu billetera MetaMask primero.');
    try {
      setLoading(true);
      setStatus({ text: 'Paso 3/5: Firma en MetaMask el despliegue de ConsorcioGovernor V2 (Quórum = 50%)...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const factory = new ethers.ContractFactory(GovernorAbi, GovernorBytecode, signer);
      // votingDelay = 10s, votingPeriod = 300s (5 min), proposalThreshold = 0, quorumPercentage = 50%
      const contract = await factory.deploy(
        activeAddresses.ConsorcioVotes,
        activeAddresses.ConsorcioTimelock,
        10,
        300,
        0,
        50
      );
      const deployTx = contract.deploymentTransaction();
      setStatus({ text: `Desplegando ConsorcioGovernor V2 (Tx: ${deployTx.hash})... Esperando confirmación...`, type: 'info' });
      const receipt = await deployTx.wait();
      const deployedAddr = await contract.getAddress();

      updateContractAddress('ConsorcioGovernor', deployedAddr);
      appendTxLog({
        accion: '3. Deploy ConsorcioGovernor V2 (Quórum 50%)',
        contrato: 'ConsorcioGovernor',
        address: deployedAddr,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `token=${activeAddresses.ConsorcioVotes}, timelock=${activeAddresses.ConsorcioTimelock}, delay=10, period=300, threshold=0, quorum=50`,
      });

      setStatus({ text: `✅ ConsorcioGovernor V2 desplegado en ${deployedAddr} (Tx: ${receipt.hash})`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al desplegar ConsorcioGovernor V2: ' + parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function handleSellarTimelockV2() {
    if (!account) return alert('Conecta tu billetera MetaMask primero.');
    try {
      setLoading(true);
      setStatus({ text: 'Paso 4/5: Firma en MetaMask configurarYSellarGobernanza en ConsorcioTimelock V2...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const timelockContract = new ethers.Contract(activeAddresses.ConsorcioTimelock, TimelockAbi, signer);
      const tx = await timelockContract.configurarYSellarGobernanza(activeAddresses.ConsorcioGovernor);
      setStatus({ text: `Sellando gobernanza en Timelock (Tx: ${tx.hash})... Esperando confirmación...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: '4. Sellar Gobernanza (configurarYSellarGobernanza)',
        contrato: 'ConsorcioTimelock',
        address: activeAddresses.ConsorcioTimelock,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `governor = ${activeAddresses.ConsorcioGovernor}`,
      });

      setStatus({ text: `✅ Gobernanza sellada atómicamente en ConsorcioTimelock V2 (Tx: ${receipt.hash})`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al sellar Timelock V2: ' + parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function handleDeployObrasV2() {
    if (!account) return alert('Conecta tu billetera MetaMask primero.');
    try {
      setLoading(true);
      setStatus({ text: 'Paso 5/5: Firma en MetaMask el despliegue de ConsorcioObras V2 (con Esquema Pull y Validación de Unidad)...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const factory = new ethers.ContractFactory(ObrasAbi, ObrasBytecode, signer);
      const contract = await factory.deploy(
        activeAddresses.ConsorcioTimelock,
        activeAddresses.ConsorcioVotes
      );
      const deployTx = contract.deploymentTransaction();
      setStatus({ text: `Desplegando ConsorcioObras V2 (Tx: ${deployTx.hash})... Esperando confirmación...`, type: 'info' });
      const receipt = await deployTx.wait();
      const deployedAddr = await contract.getAddress();

      updateContractAddress('ConsorcioObras', deployedAddr);
      appendTxLog({
        accion: '5. Deploy ConsorcioObras V2 (Pull + Validación UF)',
        contrato: 'ConsorcioObras',
        address: deployedAddr,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `timelock=${activeAddresses.ConsorcioTimelock}, consorcioVotes=${activeAddresses.ConsorcioVotes}`,
      });

      setStatus({ text: `🎉 ¡Los 4 Contratos V2 quedaron desplegados y vinculados en Sepolia! ConsorcioObras V2: ${deployedAddr}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al desplegar ConsorcioObras V2: ' + parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Carga de datos on-chain
  async function fetchProtocolData() {
    if (!window.ethereum) return;
    try {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const obrasContract = new ethers.Contract(activeAddresses.ConsorcioObras, ObrasAbi, provider);
      const votesContract = new ethers.Contract(activeAddresses.ConsorcioVotes, VotesAbi, provider);
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, provider);
      const timelockContract = new ethers.Contract(activeAddresses.ConsorcioTimelock, TimelockAbi, provider);

      // Balances del Vault
      const rawVaultBal = await provider.getBalance(activeAddresses.ConsorcioObras);
      const rawComp = await obrasContract.fondosComprometidosEnObras();
      const rawLibre = await obrasContract.saldoLibreDisponible();
      setVaultBalance(ethers.formatEther(rawVaultBal));
      setFondosComprometidos(ethers.formatEther(rawComp));
      setSaldoLibre(ethers.formatEther(rawLibre));

      // [Corrección Docente Punto 2] Pagos Pull en custodia
      try {
        const rawTotalPull = await obrasContract.totalPagosPendientesContratistas();
        setTotalPagosPull(ethers.formatEther(rawTotalPull));
        if (account) {
          const rawMiPull = await obrasContract.pagosPendientesContratista(account);
          setMiPagoPullPendiente(ethers.formatEther(rawMiPull));
        }
      } catch (_) {
        setTotalPagosPull('0');
        setMiPagoPullPendiente('0');
      }

      // Owner y Registrador actual de ConsorcioVotes [Corrección Docente Punto 6]
      const vOwner = await votesContract.owner();
      setVotesOwner(vOwner);
      try {
        const vReg = await votesContract.registrador();
        setVotesRegistrador(vReg);
      } catch (_) {
        setVotesRegistrador(vOwner);
      }

      // Guardián y Quórum de ConsorcioGovernor [Corrección Docente Puntos 1 y 5]
      try {
        const qNum = await governorContract.quorumNumerator();
        setGovernorQuorumPct(qNum.toString());
        const gAddr = await governorContract.guardian();
        setGovernorGuardian(gAddr);
      } catch (_) {}

      // Verificar si el Timelock ya otorgó roles al Governor
      const proposerRole = await timelockContract.PROPOSER_ROLE();
      const isConfigured = await timelockContract.hasRole(proposerRole, activeAddresses.ConsorcioGovernor);
      setTimelockSellado(Boolean(isConfigured));

      // Poder de voto, NFTs y delegación del usuario conectado
      if (account) {
        const [votes, nftBal, delegatee] = await Promise.all([
          votesContract.getVotes(account),
          votesContract.balanceOf(account),
          votesContract.delegates(account),
        ]);
        setUserVotes(votes.toString());
        setUserNftBalance(nftBal.toString());
        setUserDelegatee(delegatee);
      }

      // Cargar Padrón de Unidades Funcionales
      const unitResults = [];
      for (const uid of trackedUnitIds) {
        try {
          const [prop, cuota, expPagadas] = await Promise.all([
            votesContract.propietarioDeUnidad(uid),
            votesContract.cuotaParteDeUnidad(uid),
            obrasContract.expensasPagadasPorUnidad(uid),
          ]);
          let delegatario = ethers.ZeroAddress;
          if (prop !== ethers.ZeroAddress) {
            delegatario = await votesContract.delegates(prop);
          }
          unitResults.push({
            unidadId: uid,
            propietario: prop,
            cuotaParte: cuota.toString(),
            expensasPagadas: ethers.formatEther(expPagadas),
            delegatario,
          });
        } catch (_) {}
      }
      setUnidadesInfo(unitResults);

      // Actualizar ficha en vivo de la unidad seleccionada en Pagar Expensas (Caso 3)
      if (pagoUnidadId && Number(pagoUnidadId) > 0) {
        try {
          const uid = Number(pagoUnidadId);
          const [prop, cuota, expPagadas] = await Promise.all([
            votesContract.propietarioDeUnidad(uid),
            votesContract.cuotaParteDeUnidad(uid),
            obrasContract.expensasPagadasPorUnidad(uid),
          ]);
          setPagoUnidadDetalle({
            unidadId: uid,
            propietario: prop,
            cuotaParte: cuota.toString(),
            expensasPagadas: ethers.formatEther(expPagadas),
          });
        } catch (_) {
          setPagoUnidadDetalle(null);
        }
      } else {
        setPagoUnidadDetalle(null);
      }

      // Listar obras registradas
      const totalObras = await obrasContract.totalObras();
      const loadedObras = [];
      for (let i = 1; i <= Number(totalObras); i++) {
        const o = await obrasContract.obras(i);
        loadedObras.push({
          id: Number(o.id),
          nombre: o.nombre,
          descripcion: o.descripcion,
          administrador: o.administradorOContratista,
          presupuestoTotal: ethers.formatEther(o.presupuestoTotal),
          montoLiberado: ethers.formatEther(o.montoLiberado),
          estado: Number(o.estado),
          rendicion1: o.rendicionHito1Cid,
          rendicion2: o.rendicionHito2Cid,
        });
      }
      setObrasList(loadedObras);

      // Consultar estado de la propuesta activa
      if (propIdVote) {
        try {
          const st = await governorContract.state(propIdVote);
          setProposalStateInfo(Number(st));
        } catch (_) {
          setProposalStateInfo(null);
        }
      }
    } catch (err) {
      console.error('Error al cargar datos on-chain:', err);
    }
  }

  useEffect(() => {
    if (window.ethereum) {
      window.ethereum.request({ method: 'eth_accounts' }).then((accs) => {
        if (accs && accs.length > 0) {
          setAccount(accs[0]);
          window.ethereum.request({ method: 'eth_chainId' }).then((cId) => setChainId(cId));
        }
      });
      window.ethereum.on('accountsChanged', (accs) => setAccount(accs[0] || ''));
      window.ethereum.on('chainChanged', (cId) => setChainId(cId));
    }
  }, []);

  useEffect(() => {
    fetchProtocolData();
    const interval = setInterval(fetchProtocolData, 3500);
    return () => clearInterval(interval);
  }, [account, chainId, propIdVote, pagoUnidadId, trackedUnitIds, activeAddresses]);

  // ===========================================================================
  // CASO 1: Registro / Alta de Nuevos Propietarios (adjudicarUnidad)
  // ===========================================================================
  async function handleAdjudicarUnidad(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera primero.');
    try {
      setLoading(true);
      setStatus({ text: `Adjudicando Unidad #${altaUnidadId} y emitiendo NFT Soulbound...`, type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const votesContract = new ethers.Contract(activeAddresses.ConsorcioVotes, VotesAbi, signer);

      const tx = await votesContract.adjudicarUnidad(
        Number(altaUnidadId),
        altaVecinoAddr.trim(),
        Number(altaCuotaParte)
      );
      setStatus({ text: `Transacción enviada: ${tx.hash}. Acuñando NFT y auto-delegando voto...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Adjudicar Unidad #${altaUnidadId} (adjudicarUnidad)`,
        contrato: 'ConsorcioVotes',
        address: activeAddresses.ConsorcioVotes,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `unidadId=${altaUnidadId}, vecino=${altaVecinoAddr.trim()}, cuotaParte=${altaCuotaParte}`,
      });

      if (!trackedUnitIds.includes(Number(altaUnidadId))) {
        setTrackedUnitIds((prev) => [...prev, Number(altaUnidadId)].sort((a, b) => a - b));
      }

      setStatus({
        text: `🎉 ¡Unidad Funcional #${altaUnidadId} adjudicada con éxito a ${altaVecinoAddr.slice(0, 6)}...${altaVecinoAddr.slice(-4)}! Hash: ${receipt.hash}`,
        type: 'success',
      });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // ===========================================================================
  // CASO 2: Pérdida de Billetera y Recupero / Venta de Lote (reasignarUnidad)
  // ===========================================================================
  async function handleReasignarUnidad(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera primero.');
    try {
      setLoading(true);
      setStatus({ text: `Reasignando titularidad de la Unidad #${reasigUnidadId} sin _burn/_mint...`, type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const votesContract = new ethers.Contract(activeAddresses.ConsorcioVotes, VotesAbi, signer);

      const tx = await votesContract.reasignarUnidad(
        Number(reasigUnidadId),
        reasigNuevaAddr.trim()
      );
      setStatus({ text: `Reasignación enviada: ${tx.hash}. Moviendo NFT y auto-delegando voto...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Reasignar Unidad #${reasigUnidadId} (reasignarUnidad)`,
        contrato: 'ConsorcioVotes',
        address: activeAddresses.ConsorcioVotes,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `unidadId=${reasigUnidadId}, nuevoPropietario=${reasigNuevaAddr.trim()}`,
      });

      if (!trackedUnitIds.includes(Number(reasigUnidadId))) {
        setTrackedUnitIds((prev) => [...prev, Number(reasigUnidadId)].sort((a, b) => a - b));
      }

      setStatus({
        text: `🎉 ¡Unidad #${reasigUnidadId} reasignada exitosamente a ${reasigNuevaAddr.slice(0, 6)}...${reasigNuevaAddr.slice(-4)}! Hash: ${receipt.hash}`,
        type: 'success',
      });
      setReasigNuevaAddr('');
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // ===========================================================================
  // CASO 3: Inquilino o Propietario Paga las Expensas del Lote (pagarExpensas)
  // ===========================================================================
  async function handlePagarExpensas(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera primero.');
    try {
      setLoading(true);
      const isOwnerPaying =
        pagoUnidadDetalle &&
        pagoUnidadDetalle.propietario !== ethers.ZeroAddress &&
        pagoUnidadDetalle.propietario.toLowerCase() === account.toLowerCase();
      const pagadorRol = isOwnerPaying ? 'Propietario Titular' : 'Inquilino / Pagador Autorizado';

      setStatus({
        text: `Enviando pago de expensas de Unidad #${pagoUnidadId} como ${pagadorRol}...`,
        type: 'info',
      });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const obrasContract = new ethers.Contract(activeAddresses.ConsorcioObras, ObrasAbi, signer);

      const conceptoFinal = pagoConcepto || `Expensas Ordinarias - UF ${pagoUnidadId} (${pagadorRol})`;
      const tx = await obrasContract.pagarExpensas(
        Number(pagoUnidadId),
        conceptoFinal,
        { value: ethers.parseEther(pagoMonto) }
      );
      setStatus({ text: `Transacción enviada: ${tx.hash}. Esperando confirmación...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Pagar Expensas UF #${pagoUnidadId} (${pagoMonto} ETH)`,
        contrato: 'ConsorcioObras',
        address: activeAddresses.ConsorcioObras,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `unidadId=${pagoUnidadId}, valor=${pagoMonto} ETH, concepto="${conceptoFinal}"`,
      });

      if (!trackedUnitIds.includes(Number(pagoUnidadId))) {
        setTrackedUnitIds((prev) => [...prev, Number(pagoUnidadId)].sort((a, b) => a - b));
      }

      setStatus({
        text: `¡Pago de expensas exitoso imputado a expensasPagadasPorUnidad[${pagoUnidadId}] (${pagadorRol})! Hash: ${receipt.hash}`,
        type: 'success',
      });
      setPagoConcepto('');
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // ===========================================================================
  // [CORRECCIÓN DOCENTE - PUNTO 2] Retiro Pull de Pagos en Custodia
  // ===========================================================================
  async function handleRetirarPagoPull(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera primero.');
    const destino = (pullReceptorAddr || account).trim();
    if (!ethers.isAddress(destino)) {
      return alert('Ingresa una dirección receptora válida.');
    }
    try {
      setLoading(true);
      setStatus({ text: `Retirando fondos en custodia Pull hacia ${destino}...`, type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const obrasContract = new ethers.Contract(activeAddresses.ConsorcioObras, ObrasAbi, signer);

      const tx = await obrasContract.retirarPagoContratista(destino);
      const receipt = await tx.wait();

      appendTxLog({
        accion: 'Retirar Pago Contratista Pull (retirarPagoContratista)',
        contrato: 'ConsorcioObras',
        address: activeAddresses.ConsorcioObras,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `receptor=${destino}`,
      });

      setStatus({
        text: `🎉 ¡Pago en custodia Pull retirado con éxito hacia ${destino}! Hash: ${receipt.hash}`,
        type: 'success',
      });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // ===========================================================================
  // CASO 4: Inquilino Vota en Asambleas sin ser Dueño del NFT (delegate)
  // ===========================================================================
  async function handleDelegarVoto(targetAddress) {
    if (!account) return alert('Conecta tu billetera primero.');
    const destino = (targetAddress || delegateTargetAddr || '').trim();
    if (!ethers.isAddress(destino)) {
      setStatus({ text: '⚠️ Ingresa una dirección de billetera Ethereum válida (0x...).', type: 'warning' });
      return;
    }
    try {
      setLoading(true);
      const esRecuperoPropio = destino.toLowerCase() === account.toLowerCase();
      setStatus({
        text: esRecuperoPropio
          ? 'Recuperando tu poder de voto (Auto-delegación en ConsorcioVotes)...'
          : `Cediendo poder de voto temporalmente al inquilino (${destino.slice(0, 6)}...${destino.slice(-4)}) conservando tu NFT Soulbound...`,
        type: 'info',
      });

      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const votesContract = new ethers.Contract(activeAddresses.ConsorcioVotes, VotesAbi, signer);

      const tx = await votesContract.delegate(destino);
      setStatus({ text: `Transacción de delegación enviada: ${tx.hash}. Confirmando...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: esRecuperoPropio ? 'Recuperar Voto Propio (delegate)' : 'Delegar Voto a Inquilino (delegate)',
        contrato: 'ConsorcioVotes',
        address: activeAddresses.ConsorcioVotes,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `delegatee=${destino}`,
      });

      setStatus({
        text: esRecuperoPropio
          ? `🎉 ¡Poder de voto recuperado con éxito! Hash: ${receipt.hash}`
          : `🎉 ¡Poder de voto delegado al inquilino (${destino.slice(0, 6)}...${destino.slice(-4)})! Hash: ${receipt.hash}`,
        type: 'success',
      });
      setDelegateTargetAddr('');
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // ===========================================================================
  // CASO 5: Votación Gasless por Firma EIP-712 (castVoteBySig)
  // ===========================================================================
  async function handleFirmarVotoGasless(foundryActor = null) {
    if (!foundryActor && !account) return alert('Conecta tu billetera primero.');
    if (!propIdVote) {
      setStatus({ text: '⚠️ Ingresa o crea primero el Proposal ID que deseas votar.', type: 'warning' });
      return;
    }
    try {
      setLoading(true);
      const voterAddress = foundryActor ? foundryActor.address : account;
      const voterName = foundryActor ? foundryActor.nombre : 'Tu MetaMask';
      setStatus({ text: `Preparando estructura criptográfica EIP-712 (Ballot) libre de gas para ${voterName}...`, type: 'info' });

      const provider = new ethers.BrowserProvider(window.ethereum);
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, provider);

      const [domainInfo, voterNonce] = await Promise.all([
        governorContract.eip712Domain(),
        governorContract.nonces(voterAddress),
      ]);

      const domain = {
        name: domainInfo[1] || 'ConsorcioGovernor',
        version: domainInfo[2] || '1',
        chainId: Number(domainInfo[3] || 11155111),
        verifyingContract: activeAddresses.ConsorcioGovernor,
      };

      const types = {
        Ballot: [
          { name: 'proposalId', type: 'uint256' },
          { name: 'support', type: 'uint8' },
          { name: 'voter', type: 'address' },
          { name: 'nonce', type: 'uint256' },
        ],
      };

      const message = {
        proposalId: BigInt(propIdVote),
        support: Number(voteSupport),
        voter: voterAddress,
        nonce: BigInt(voterNonce),
      };

      let signature;
      if (foundryActor && foundryActor.pk) {
        const foundryWallet = new ethers.Wallet(foundryActor.pk);
        signature = await foundryWallet.signTypedData(domain, types, message);
      } else {
        const signer = await provider.getSigner();
        setStatus({ text: '🖋️ Por favor firma el cupón EIP-712 en MetaMask (0 Gas - Firma Off-Chain)...', type: 'info' });
        signature = await signer.signTypedData(domain, types, message);
      }

      const signedPackage = {
        actorNombre: voterName,
        proposalId: propIdVote.toString(),
        support: Number(voteSupport),
        voter: voterAddress,
        nonce: voterNonce.toString(),
        signature,
      };

      setSigData(signedPackage);
      setManualSigProposalId(signedPackage.proposalId);
      setManualSigSupport(String(signedPackage.support));
      setManualSigVoter(signedPackage.voter);
      setManualSigHex(signedPackage.signature);

      setStatus({
        text: `🎉 ¡Voto de ${voterName} firmado con EIP-712 (0 Gas)! Ahora haz clic en "🚀 Paso 2: Enviar Voto Firmado al Contrato (castVoteBySig)".`,
        type: 'success',
      });
    } catch (err) {
      console.error(err);
      setStatus({ text: 'Error al firmar voto EIP-712: ' + (err.shortMessage || err.message), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  async function handleEnviarVotoPorFirma(e) {
    if (e) e.preventDefault();
    if (!account) return alert('Conecta tu billetera primero.');
    const pId = (manualSigProposalId || propIdVote || '').trim();
    const supp = Number(manualSigSupport);
    const vtr = (manualSigVoter || '').trim();
    const sig = (manualSigHex || '').trim();

    if (!pId || !ethers.isAddress(vtr) || !sig.startsWith('0x')) {
      setStatus({ text: '⚠️ Completa todos los campos de la firma EIP-712 (Proposal ID, Votante y Signature 0x...).', type: 'warning' });
      return;
    }

    try {
      setLoading(true);
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);

      const currentState = await governorContract.state(pId);
      if (Number(currentState) !== 1) {
        setStatus({
          text: `⚠️ La propuesta no está en estado Active (Estado actual: ${ESTADO_PROPUESTA_NOMBRES[Number(currentState)] || currentState}). Debes enviar la firma durante la ventana de votación abierta.`,
          type: 'warning',
        });
        setLoading(false);
        return;
      }

      setStatus({ text: `Enviando voto firmado por ${vtr.slice(0, 6)}...${vtr.slice(-4)} vía castVoteBySig...`, type: 'info' });
      const tx = await governorContract.castVoteBySig(pId, supp, vtr, sig);
      setStatus({ text: `Transacción castVoteBySig enviada: ${tx.hash}. Minando...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Voto Gasless EIP-712 (castVoteBySig) por ${vtr}`,
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${pId}, support=${supp}, voter=${vtr}`,
      });

      setStatus({
        text: `🎉 ¡Voto Gasless EIP-712 de ${vtr.slice(0, 6)}...${vtr.slice(-4)} registrado en la blockchain con éxito! Hash: ${receipt.hash}`,
        type: 'success',
      });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Transacción: Proponer en Governor
  async function handleCrearPropuesta(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      setStatus({ text: 'Creando propuesta on-chain en ConsorcioGovernor...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);
      const obrasInterface = new ethers.Interface(ObrasAbi);

      const convocatoriaTag = `[Llamado ${new Date().toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}]`;

      let targets, values, calldatas, desc;
      if (propTipo === 'liberarHito2') {
        targets = [activeAddresses.ConsorcioObras];
        values = [0];
        calldatas = [obrasInterface.encodeFunctionData('liberarHito2', [Number(propObraId)])];
        desc = `Propuesta Obra #${propObraId}: Aprobar Rendicion y Liberar Hito 2 (40%) ${convocatoriaTag}`;
      } else if (propTipo === 'liberarHito3') {
        targets = [activeAddresses.ConsorcioObras];
        values = [0];
        calldatas = [obrasInterface.encodeFunctionData('liberarHito3Final', [Number(propObraId), 'ipfs://ActaRecepcionDefinitiva'])];
        desc = `Propuesta Obra #${propObraId}: Aprobacion Final y Liquidacion Hito 3 (30%) ${convocatoriaTag}`;
      } else {
        targets = [activeAddresses.ConsorcioObras];
        values = [0];
        calldatas = [
          obrasInterface.encodeFunctionData('aprobarObraYLiberarHito1', [
            propNombre,
            propDesc,
            propContratista,
            ethers.parseEther(propPresupuesto),
          ]),
        ];
        desc = `Propuesta Obra: ${propNombre} - ${propDesc} ${convocatoriaTag}`;
      }
      const descHash = ethers.id(desc);

      const tx = await governorContract.propose(targets, values, calldatas, desc);
      setStatus({ text: `Propuesta enviada: ${tx.hash}. Esperando confirmación...`, type: 'info' });
      const receipt = await tx.wait();
      let createdPropId = '';
      for (const log of receipt.logs) {
        try {
          const parsed = governorContract.interface.parseLog(log);
          if (parsed && parsed.name === 'ProposalCreated') {
            createdPropId = parsed.args.proposalId.toString();
            break;
          }
        } catch (_) {}
      }

      appendTxLog({
        accion: `Crear Propuesta en Governor (propose)`,
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${createdPropId}, desc="${desc}"`,
      });

      const propData = { targets, values, calldatas, desc, descHash, tipo: propTipo, obraId: propObraId };
      setPropActiveData(propData);
      try {
        localStorage.setItem('last_proposal_data', JSON.stringify(propData));
      } catch (_) {}

      if (createdPropId) {
        setPropIdVote(createdPropId);
        setProposalStateInfo(0);
        try {
          localStorage.setItem('last_active_proposal_id', createdPropId);
        } catch (_) {}
        setStatus({
          text: `¡Propuesta creada con éxito! ID: ${createdPropId}. (Cargada automáticamente en el formulario de votación).`,
          type: 'success',
        });
      } else {
        setStatus({ text: `¡Propuesta creada con éxito! Hash: ${receipt.hash}`, type: 'success' });
      }
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Transacción: Votar en Governor
  async function handleVotar(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);

      const currentState = await governorContract.state(propIdVote);
      if (Number(currentState) === 0) {
        setStatus({
          text: '⏳ La propuesta está en período de deliberación previo (Pending). Espera unos 10 a 20 segundos para que inicie la votación.',
          type: 'warning',
        });
        setLoading(false);
        return;
      }
      if (Number(currentState) !== 1) {
        setStatus({
          text: `⚠️ La propuesta no está abierta para votación (Estado: ${ESTADO_PROPUESTA_NOMBRES[Number(currentState)] || currentState}).`,
          type: 'warning',
        });
        setLoading(false);
        return;
      }

      setStatus({ text: 'Emitiendo voto en ConsorcioGovernor...', type: 'info' });
      const tx = await governorContract.castVote(propIdVote, Number(voteSupport));
      setStatus({ text: `Voto emitido: ${tx.hash}. Minando...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Emitir Voto Directo (castVote)`,
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${propIdVote}, support=${voteSupport}`,
      });

      setStatus({ text: `¡Voto registrado en la blockchain! Hash: ${receipt.hash}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Transacción: Encolar Propuesta aprobada en Timelock (Queue)
  async function handleEncolarPropuesta() {
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      setStatus({ text: 'Encolando propuesta aprobada en Timelock...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);
      const obrasInterface = new ethers.Interface(ObrasAbi);

      const targets = propActiveData?.targets || [activeAddresses.ConsorcioObras];
      const values = propActiveData?.values || [0];
      const calldatas = propActiveData?.calldatas || [
        obrasInterface.encodeFunctionData('liberarHito2', [Number(propObraId || '1')]),
      ];
      const descHash = propActiveData?.descHash || ethers.id(
        propActiveData?.desc || `Propuesta Obra #${propObraId || '1'}: Aprobar Rendicion y Liberar Hito 2 (40%)`
      );

      const tx = await governorContract.queue(targets, values, calldatas, descHash);
      setStatus({ text: `Propuesta encolada: ${tx.hash}. Esperando confirmación...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: 'Encolar Propuesta en Timelock (queue)',
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${propIdVote}`,
      });

      setStatus({ text: `¡Propuesta encolada en Timelock con éxito! Ahora tienes 60s de ventana de seguridad antes de ejecutar. Hash: ${receipt.hash}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // [CORRECCIÓN DOCENTE - PUNTO 5] Cancelar propuesta en estado Queued durante minDelay
  async function handleCancelarPropuestaEnCola() {
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      setStatus({ text: 'Cancelando propuesta encolada durante ventana de seguridad (cancelarPropuestaEnCola)...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);
      const obrasInterface = new ethers.Interface(ObrasAbi);

      const targets = propActiveData?.targets || [activeAddresses.ConsorcioObras];
      const values = propActiveData?.values || [0];
      const calldatas = propActiveData?.calldatas || [
        obrasInterface.encodeFunctionData('liberarHito2', [Number(propObraId || '1')]),
      ];
      const descHash = propActiveData?.descHash || ethers.id(
        propActiveData?.desc || `Propuesta Obra #${propObraId || '1'}: Aprobar Rendicion y Liberar Hito 2 (40%)`
      );

      const tx = await governorContract.cancelarPropuestaEnCola(targets, values, calldatas, descHash);
      setStatus({ text: `Cancelación enviada: ${tx.hash}. Esperando confirmación...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: 'Cancelar Propuesta en Cola (cancelarPropuestaEnCola - Corrección Docente Punto 5)',
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${propIdVote}`,
      });

      setStatus({ text: `🛑 ¡Propuesta encolada cancelada exitosamente durante la ventana de seguridad del Timelock! Hash: ${receipt.hash}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Transacción: Ejecutar Propuesta en Timelock (Execute)
  async function handleEjecutarPropuesta() {
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      setStatus({ text: 'Ejecutando propuesta en Timelock y transfiriendo fondos...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const governorContract = new ethers.Contract(activeAddresses.ConsorcioGovernor, GovernorAbi, signer);
      const obrasInterface = new ethers.Interface(ObrasAbi);

      const targets = propActiveData?.targets || [activeAddresses.ConsorcioObras];
      const values = propActiveData?.values || [0];
      const calldatas = propActiveData?.calldatas || [
        obrasInterface.encodeFunctionData('liberarHito2', [Number(propObraId || '1')]),
      ];
      const descHash = propActiveData?.descHash || ethers.id(
        propActiveData?.desc || `Propuesta Obra #${propObraId || '1'}: Aprobar Rendicion y Liberar Hito 2 (40%)`
      );

      const tx = await governorContract.execute(targets, values, calldatas, descHash);
      setStatus({ text: `Ejecutando propuesta: ${tx.hash}. Minando...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: 'Ejecutar Propuesta en Timelock (execute)',
        contrato: 'ConsorcioGovernor',
        address: activeAddresses.ConsorcioGovernor,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `proposalId=${propIdVote}`,
      });

      setStatus({ text: `🎉 ¡Propuesta ejecutada y fondos transferidos con éxito! Hash: ${receipt.hash}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  // Carga de archivo a Pinata IPFS
  async function handleUploadFileToPinata(e) {
    const file = e.target.files?.[0];
    if (!file) return;

    try {
      setUploadingIpfs(true);
      setStatus({ text: `Subiendo "${file.name}" a Pinata IPFS...`, type: 'info' });

      const formData = new FormData();
      formData.append('file', file);

      const metadata = JSON.stringify({
        name: `ConsorcioDAO_Obra${rendicionObraId}_Hito${rendicionHitoNum}_${file.name}`,
        keyvalues: {
          obraId: String(rendicionObraId),
          hito: String(rendicionHitoNum),
          uploader: account || 'Desconocido',
        },
      });
      formData.append('pinataMetadata', metadata);
      formData.append('pinataOptions', JSON.stringify({ cidVersion: 0 }));

      const res = await fetch('https://api.pinata.cloud/pinning/pinFileToIPFS', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${DEFAULT_PINATA_JWT}`,
        },
        body: formData,
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({}));
        throw new Error(errData.error?.details || errData.error || `HTTP ${res.status}`);
      }

      const data = await res.json();
      const newCid = `ipfs://${data.IpfsHash}`;
      setRendicionCid(newCid);
      setUploadedFileInfo({
        name: file.name,
        size: (file.size / 1024).toFixed(1) + ' KB',
        cid: data.IpfsHash,
        url: `${PINATA_GATEWAY_URL}/${data.IpfsHash}`,
      });

      setStatus({
        text: `🎉 ¡Comprobante subido a Pinata IPFS con éxito! Hash CID: ${data.IpfsHash}`,
        type: 'success',
      });
    } catch (err) {
      console.error('Error al subir a Pinata:', err);
      setStatus({ text: `Error al subir a Pinata IPFS: ${err.message}`, type: 'error' });
    } finally {
      setUploadingIpfs(false);
    }
  }

  // Transacción: Rendir Cuentas de Hito
  async function handleRendirCuentas(e) {
    e.preventDefault();
    if (!account) return alert('Conecta tu billetera.');
    try {
      setLoading(true);
      setStatus({ text: 'Registrando comprobantes IPFS on-chain...', type: 'info' });
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const obrasContract = new ethers.Contract(activeAddresses.ConsorcioObras, ObrasAbi, signer);

      let tx;
      if (rendicionHitoNum === '1') {
        tx = await obrasContract.rendirCuentasHito1(Number(rendicionObraId), rendicionCid);
      } else {
        tx = await obrasContract.rendirCuentasHito2(Number(rendicionObraId), rendicionCid);
      }
      setStatus({ text: `Rendición enviada: ${tx.hash}. Esperando...`, type: 'info' });
      const receipt = await tx.wait();

      appendTxLog({
        accion: `Rendir Cuentas Hito ${rendicionHitoNum} Obra #${rendicionObraId}`,
        contrato: 'ConsorcioObras',
        address: activeAddresses.ConsorcioObras,
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        args: `obraId=${rendicionObraId}, cid="${rendicionCid}"`,
      });

      setStatus({ text: `¡Rendición de cuentas asentada on-chain! Hash: ${receipt.hash}`, type: 'success' });
      fetchProtocolData();
    } catch (err) {
      console.error(err);
      setStatus({ text: parseContractError(err), type: 'error' });
    } finally {
      setLoading(false);
    }
  }

  const isConnectedAuthorizedForVotes =
    account &&
    ((votesOwner && account.toLowerCase() === votesOwner.toLowerCase()) ||
      (votesRegistrador && account.toLowerCase() === votesRegistrador.toLowerCase()));

  const identidadHashPreview = reasigDniEmail.trim()
    ? ethers.id(reasigDniEmail.trim().toLowerCase())
    : null;

  return (
    <div className="container">
      <header>
        <div className="logo-area">
          <h1>
            🏛️ ADM-Consorcios{' '}
            <span className="badge badge-success" style={{ fontSize: '0.85rem', verticalAlign: 'middle' }}>
              Edición Final TP v2
            </span>
          </h1>
          <p>
            Quórum Estatutario {governorQuorumPct}% · Esquema Híbrido Push+Pull · Validación On-Chain de UF · Ventana de Seguridad Queued · Doble Vía Registral
          </p>
        </div>
        <div>
          {account ? (
            <div style={{ textAlign: 'right' }}>
              <span className="badge badge-success">MetaMask Conectada</span>
              <div className="mono" style={{ marginTop: '4px' }}>
                {account.slice(0, 6)}...{account.slice(-4)}
              </div>
            </div>
          ) : (
            <button className="wallet-btn" onClick={connectWallet} disabled={loading}>
              🦊 Conectar MetaMask
            </button>
          )}
        </div>
      </header>

      {/* Dashboard de Estado y Semáforos */}
      <div className="dashboard-header">
        <div className="dashboard-item">
          <span className="badge badge-success">Vault Balance</span>
          <span className={`semaphore ${parseFloat(vaultBalance) > 0 ? 'green' : 'red'}`}></span>
          <span>{parseFloat(vaultBalance).toFixed(4)} ETH</span>
        </div>
        <div className="dashboard-item">
          <span className="badge badge-warning">Poder de Voto / Quórum V2</span>
          <span className={`semaphore ${parseInt(userVotes) > 0 ? 'green' : 'red'}`}></span>
          <span>{userVotes} Votos ({userNftBalance} NFT) · Quórum {governorQuorumPct}%</span>
        </div>
        <div className="dashboard-item">
          <span className="badge badge-info">Timelock Protocol</span>
          <span className={`semaphore ${timelockSellado ? 'green' : 'red'}`}></span>
          <span>{timelockSellado ? 'Sellado / Activo' : 'Pendiente de Sellado'}</span>
        </div>
      </div>

      {/* Tarjetas de Métricas Principales */}
      <div className="grid-cards">
        <div className="card">
          <h2>Saldo Total Vault <span>💰</span></h2>
          <div className="val">{parseFloat(vaultBalance).toFixed(4)} ETH</div>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>Fondos totales custodiados</p>
        </div>
        <div className="card">
          <h2>Comprometido + Pull <span>🔒</span></h2>
          <div className="val" style={{ color: '#f59e0b' }}>
            {(parseFloat(fondosComprometidos) + parseFloat(totalPagosPull)).toFixed(4)} ETH
          </div>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>
            Obras: {parseFloat(fondosComprometidos).toFixed(4)} | Pull: {parseFloat(totalPagosPull).toFixed(4)} ETH
          </p>
        </div>
        <div className="card">
          <h2>Saldo Libre Disponible <span>🟢</span></h2>
          <div className="val" style={{ color: '#10b981' }}>{parseFloat(saldoLibre).toFixed(4)} ETH</div>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>Disponible para nuevas obras</p>
        </div>
        <div className="card">
          <h2>Tus Votos Activos <span>🗳️</span></h2>
          <div className="val" style={{ color: '#a855f7' }}>{userVotes}</div>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>
            {Number(userNftBalance) > 0 && Number(userVotes) === 0
              ? '🔑 Voto delegado a un Inquilino'
              : Number(userNftBalance) === 0 && Number(userVotes) > 0
              ? '🔑 Votando como Inquilino Delegado'
              : `Propios: ${userNftBalance} NFT Soulbound`}
          </p>
          {Number(userNftBalance) > 0 && Number(userVotes) === 0 && (
            <button
              type="button"
              onClick={() => handleDelegarVoto(account)}
              disabled={loading}
              style={{
                marginTop: '8px',
                width: '100%',
                padding: '6px 10px',
                fontSize: '0.78rem',
                fontWeight: 700,
                borderRadius: '6px',
                border: '1px solid #34d399',
                background: 'linear-gradient(135deg, #10b981 0%, #059669 100%)',
                color: '#ffffff',
                cursor: 'pointer',
              }}
            >
              🔄 Recuperar mi Voto Ahora
            </button>
          )}
        </div>
      </div>

      {status.text && (
        <div className={`status-msg ${status.type}`}>
          {status.text}
        </div>
      )}

      {/* Navegación por pestañas */}
      <div className="tab-nav" style={{ marginTop: '24px' }}>
        <button
          className={`tab-btn ${activeTab === 'obras' ? 'active' : ''}`}
          onClick={() => setActiveTab('obras')}
        >
          🏗️ Obras y Custodia Pull ({obrasList.length})
        </button>
        <button
          className={`tab-btn ${activeTab === 'unidades' ? 'active' : ''}`}
          onClick={() => setActiveTab('unidades')}
        >
          🏘️ Unidades y Doble Vía Registral
        </button>
        <button
          className={`tab-btn ${activeTab === 'pagar' ? 'active' : ''}`}
          onClick={() => setActiveTab('pagar')}
        >
          💳 Pagar Expensas (Validación UF)
        </button>
        <button
          className={`tab-btn ${activeTab === 'gobernanza' ? 'active' : ''}`}
          onClick={() => setActiveTab('gobernanza')}
        >
          ⚖️ Gobernanza, Cancelación Queued y EIP-712
        </button>
        <button
          className={`tab-btn ${activeTab === 'rendir' ? 'active' : ''}`}
          onClick={() => setActiveTab('rendir')}
        >
          📋 Rendición de Cuentas (IPFS)
        </button>
        <button
          className={`tab-btn ${activeTab === 'contratos' ? 'active' : ''}`}
          onClick={() => setActiveTab('contratos')}
        >
          📜 Contratos en Etherscan
        </button>
      </div>

      {/* Pestaña: Obras y Custodia Pull */}
      {activeTab === 'obras' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          <div className="card">
            <h2>Obras de Espacio Común Registradas</h2>
            <p style={{ color: 'var(--text-muted)', fontSize: '0.85rem', marginBottom: '16px' }}>
              Cada obra divide su presupuesto en 3 etapas estrictas: Hito 1 (30% anticipo), Hito 2 (40% avance con rendición previa) y Hito 3 (30% entrega final).
            </p>
            {obrasList.length === 0 ? (
              <p style={{ color: 'var(--text-muted)' }}>No hay obras registradas aún en este contrato ConsorcioObras V2.</p>
            ) : (
              <div className="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th>Nombre / Descripción</th>
                      <th>Contratista</th>
                      <th>Presupuesto Total</th>
                      <th>Monto Liberado</th>
                      <th>Estado de Hitos</th>
                    </tr>
                  </thead>
                  <tbody>
                    {obrasList.map((o) => (
                      <tr key={o.id}>
                        <td className="mono">#{o.id}</td>
                        <td>
                          <strong>{o.nombre}</strong>
                          <div style={{ color: 'var(--text-muted)', fontSize: '0.78rem' }}>{o.descripcion}</div>
                        </td>
                        <td className="mono">
                          <a
                            className="etherscan-link"
                            href={`${ETHERSCAN_BASE_URL}/address/${o.administrador}`}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {o.administrador.slice(0, 6)}...{o.administrador.slice(-4)}
                          </a>
                        </td>
                        <td>{o.presupuestoTotal} ETH</td>
                        <td>
                          <div style={{ color: '#38bdf8' }}>{o.montoLiberado} ETH</div>
                          <div className="progress-bar" style={{ marginTop: '4px' }}>
                            <div className="progress" style={{ width: `${(parseFloat(o.montoLiberado) / parseFloat(o.presupuestoTotal)) * 100}%` }} />
                          </div>
                          <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                            {((parseFloat(o.montoLiberado) / parseFloat(o.presupuestoTotal)) * 100).toFixed(1)}%
                          </div>
                        </td>
                        <td>
                          <span className={`badge ${o.estado === 6 ? 'badge-success' : 'badge-warning'}`}>
                            {ESTADO_OBRA_NOMBRES[o.estado] || 'Desconocido'}
                          </span>
                          {o.rendicion1 && (
                            <div style={{ marginTop: '6px' }}>
                              <a
                                href={`${PINATA_GATEWAY_URL}/${o.rendicion1.replace('ipfs://', '')}`}
                                target="_blank"
                                rel="noreferrer"
                                className="etherscan-link"
                                style={{ fontSize: '0.78rem', display: 'inline-flex', alignItems: 'center', gap: '4px' }}
                              >
                                📄 Factura Hito 1 (IPFS) ↗
                              </a>
                            </div>
                          )}
                          {o.rendicion2 && (
                            <div style={{ marginTop: '4px' }}>
                              <a
                                href={`${PINATA_GATEWAY_URL}/${o.rendicion2.replace('ipfs://', '')}`}
                                target="_blank"
                                rel="noreferrer"
                                className="etherscan-link"
                                style={{ fontSize: '0.78rem', display: 'inline-flex', alignItems: 'center', gap: '4px' }}
                              >
                                📄 Factura Hito 2 (IPFS) ↗
                              </a>
                            </div>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* [CORRECCIÓN DOCENTE - PUNTO 2] Panel de Retiro Pull para Contratistas */}
          <div className="card">
            <h2>💸 Custodia Pull de Contratistas (<code>retirarPagoContratista</code> — Corrección Docente Punto 2)</h2>
            <p style={{ color: 'var(--text-muted)', fontSize: '0.84rem', marginBottom: '12px' }}>
              Si al liberarse un hito la billetera del contratista es un contrato inteligente que rechaza transferencias directas de ETH, el pago no bloquea al Timelock: queda resguardado en <code>pagosPendientesContratista</code> para que el contratista lo retire aquí hacia cualquier dirección operativa.
            </p>
            <div style={{ display: 'flex', gap: '20px', flexWrap: 'wrap', marginBottom: '12px', fontSize: '0.85rem' }}>
              <div>
                <strong>Total en Custodia Pull del Vault:</strong>{' '}
                <span className="mono" style={{ color: '#f59e0b' }}>{parseFloat(totalPagosPull).toFixed(4)} ETH</span>
              </div>
              <div>
                <strong>Tu Saldo Pendiente de Retiro Pull:</strong>{' '}
                <span className="mono" style={{ color: '#10b981' }}>{parseFloat(miPagoPullPendiente).toFixed(4)} ETH</span>
              </div>
            </div>
            <form onSubmit={handleRetirarPagoPull} style={{ display: 'flex', gap: '10px', flexWrap: 'wrap', alignItems: 'flex-end' }}>
              <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                <label>Dirección Receptora del Retiro (<code>receptor</code>):</label>
                <input
                  type="text"
                  className="form-input mono"
                  placeholder={account || '0x...'}
                  value={pullReceptorAddr}
                  onChange={(e) => setPullReceptorAddr(e.target.value)}
                />
              </div>
              <button
                type="submit"
                className="action-btn"
                style={{ width: 'auto', padding: '10px 20px' }}
                disabled={loading || parseFloat(miPagoPullPendiente) === 0}
              >
                💸 Retirar Pago en Custodia Pull
              </button>
            </form>
          </div>
        </div>
      )}

      {/* =====================================================================
          PESTAÑA UNIDADES, PROPIETARIOS E INQUILINOS (INCLUYE CORRECCIÓN DOCENTE PUNTO 6)
         ===================================================================== */}
      {activeTab === 'unidades' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          <div className="card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '12px', marginBottom: '12px' }}>
              <div>
                <h2>🏘️ Padrón On-Chain de Unidades Funcionales (ConsorcioVotes V2)</h2>
                <p style={{ color: 'var(--text-muted)', fontSize: '0.84rem' }}>
                  [Corrección Docente Punto 6] Esquema de doble vía (<code>onlyRegistradorOrOwner</code>): el <strong>Registrador Operativo</strong> ejecuta altas y recuperos en 1 paso y el <strong>Timelock (Owner)</strong> conserva la soberanía suprema.
                </p>
              </div>
              <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                <input
                  type="number"
                  className="form-input"
                  style={{ width: '140px', padding: '8px 10px' }}
                  placeholder="Buscar UF (ej. 105)"
                  value={customUnitSearch}
                  onChange={(e) => setCustomUnitSearch(e.target.value)}
                />
                <button
                  type="button"
                  className="wallet-btn"
                  style={{ padding: '8px 14px', fontSize: '0.82rem' }}
                  onClick={() => {
                    const n = Number(customUnitSearch);
                    if (n > 0 && !trackedUnitIds.includes(n)) {
                      setTrackedUnitIds((prev) => [...prev, n].sort((a, b) => a - b));
                    }
                    setCustomUnitSearch('');
                  }}
                >
                  ➕ Consultar Lote
                </button>
              </div>
            </div>

            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Unidad / Lote</th>
                    <th>Estado NFT</th>
                    <th>Propietario Titular (Soulbound)</th>
                    <th>Quién Vota en Asamblea (Delegatee)</th>
                    <th>Alícuota</th>
                    <th>Expensas Acumuladas</th>
                  </tr>
                </thead>
                <tbody>
                  {unidadesInfo.map((u) => {
                    const adjudicada = u.propietario !== ethers.ZeroAddress;
                    const delegadoAInquilino =
                      adjudicada &&
                      u.delegatario !== ethers.ZeroAddress &&
                      u.delegatario.toLowerCase() !== u.propietario.toLowerCase();
                    const propLabel = getActorLabel(u.propietario);
                    const delLabel = getActorLabel(u.delegatario);
                    return (
                      <tr key={u.unidadId}>
                        <td className="mono"><strong>UF #{u.unidadId}</strong></td>
                        <td>
                          {adjudicada ? (
                            <span className="badge badge-success">Adjudicada (NFT #{u.unidadId})</span>
                          ) : (
                            <span className="badge badge-warning">Vacante / Sin Emitir</span>
                          )}
                        </td>
                        <td className="mono">
                          {adjudicada ? (
                            <div>
                              {propLabel && (
                                <div style={{ fontSize: '0.76rem', color: '#38bdf8', fontWeight: 600, marginBottom: '2px' }}>
                                  {propLabel}
                                </div>
                              )}
                              <a
                                className="etherscan-link"
                                href={`${ETHERSCAN_BASE_URL}/address/${u.propietario}`}
                                target="_blank"
                                rel="noreferrer"
                              >
                                {u.propietario.slice(0, 6)}...{u.propietario.slice(-4)}
                              </a>
                            </div>
                          ) : (
                            <span style={{ color: 'var(--text-muted)' }}>—</span>
                          )}
                        </td>
                        <td className="mono">
                          {!adjudicada ? (
                            <span style={{ color: 'var(--text-muted)' }}>—</span>
                          ) : delegadoAInquilino ? (
                            <div>
                              <span className="badge badge-info" style={{ marginRight: '6px' }}>🔑 Inquilino / Delegado</span>
                              {delLabel && <span style={{ fontSize: '0.75rem', color: '#e9d5ff', marginRight: '6px' }}>{delLabel}</span>}
                              <span className="mono">{u.delegatario.slice(0, 6)}...{u.delegatario.slice(-4)}</span>
                            </div>
                          ) : (
                            <div>
                              <span className="badge badge-success" style={{ marginRight: '6px' }}>🏠 Propietario Directo</span>
                              <span className="mono">{u.propietario.slice(0, 6)}...{u.propietario.slice(-4)}</span>
                            </div>
                          )}
                        </td>
                        <td>{adjudicada ? `${u.cuotaParte} pts` : '—'}</td>
                        <td className="mono" style={{ color: '#38bdf8', fontWeight: 600 }}>
                          {parseFloat(u.expensasPagadas).toFixed(4)} ETH
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: '20px' }}>
            {/* CASO 1: Registro / Alta de Nuevos Propietarios */}
            <div className="card">
              <h2>1️⃣ Alta de Nuevo Propietario (<code>adjudicarUnidad</code>)</h2>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.82rem', marginBottom: '12px' }}>
                Acuña el NFT Soulbound (<code>tokenId = unidadId</code>) a favor del vecino y le <strong>auto-delega el poder de voto</strong> en el mismo acto.
              </p>

              <div style={{ marginBottom: '12px' }}>
                <div style={{ fontSize: '0.76rem', color: '#94a3b8', marginBottom: '6px', fontWeight: 600 }}>
                  ⚡ Cargar Actor de Comunidad Foundry (1 clic):
                </div>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
                  {[ACTORES_FOUNDRY.alice, ACTORES_FOUNDRY.bob, ACTORES_FOUNDRY.carlos, ACTORES_FOUNDRY.diana].map((act) => (
                    <button
                      key={act.uf}
                      type="button"
                      onClick={() => {
                        setAltaUnidadId(String(act.uf));
                        setAltaVecinoAddr(act.address);
                        setAltaCuotaParte(String(act.cuota));
                      }}
                      style={{
                        background: 'rgba(37, 99, 235, 0.22)',
                        border: '1px solid rgba(56, 189, 248, 0.45)',
                        color: '#e0f2fe',
                        padding: '5px 9px',
                        borderRadius: '6px',
                        fontSize: '0.75rem',
                        cursor: 'pointer',
                        fontWeight: 600,
                      }}
                    >
                      {act.nombre}
                    </button>
                  ))}
                </div>
              </div>

              <div style={{ marginBottom: '12px', padding: '8px 12px', background: 'rgba(16, 185, 129, 0.12)', border: '1px solid rgba(16, 185, 129, 0.35)', borderRadius: '8px', fontSize: '0.78rem' }}>
                <div>
                  🛡️ <strong>Registrador Operativo (1 Paso):</strong>{' '}
                  <span className="mono">{votesRegistrador.slice(0, 6)}...{votesRegistrador.slice(-4)}</span>
                </div>
                <div style={{ marginTop: '4px' }}>
                  🏛️ <strong>Owner Supremo:</strong>{' '}
                  <span className="mono">{votesOwner.slice(0, 6)}...{votesOwner.slice(-4)}</span>{' '}
                  {isConnectedAuthorizedForVotes ? (
                    <span className="badge badge-success" style={{ marginLeft: '4px' }}>Autorizado</span>
                  ) : (
                    <span className="badge badge-warning" style={{ marginLeft: '4px' }}>Solo Lectura</span>
                  )}
                </div>
              </div>
              <form onSubmit={handleAdjudicarUnidad}>
                <div className="form-group">
                  <label>Número de Unidad Funcional / Lote (<code>unidadId</code>):</label>
                  <input
                    type="number"
                    className="form-input"
                    placeholder="Ej. 101"
                    value={altaUnidadId}
                    onChange={(e) => setAltaUnidadId(e.target.value)}
                    required
                  />
                </div>
                <div className="form-group">
                  <label>Billetera del Propietario (<code>vecino</code>):</label>
                  <input
                    type="text"
                    className="form-input mono"
                    placeholder="0x..."
                    value={altaVecinoAddr}
                    onChange={(e) => setAltaVecinoAddr(e.target.value)}
                    required
                  />
                </div>
                <div className="form-group">
                  <label>Alícuota / Cuota Parte (<code>cuotaParte &gt; 0</code>):</label>
                  <input
                    type="number"
                    className="form-input"
                    placeholder="Ej. 100"
                    value={altaCuotaParte}
                    onChange={(e) => setAltaCuotaParte(e.target.value)}
                    required
                  />
                </div>
                <button className="action-btn" type="submit" disabled={loading}>
                  {loading ? 'Emitiendo NFT Soulbound...' : '🏠 Adjudicar Unidad y Activar Voto'}
                </button>
              </form>
            </div>

            {/* CASO 2: Pérdida de Billetera y Recupero del Voto / Venta del Lote */}
            <div className="card">
              <h2>2️⃣ Recupero de Billetera o Venta (<code>reasignarUnidad</code>)</h2>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.82rem', marginBottom: '12px' }}>
                Mueve el NFT Soulbound de la billetera extraviada o vendedora a la <code>nuevaBilletera</code> sin usar <code>_burn/_mint</code> (~30% menos gas) y le auto-delega el voto en el acto.
              </p>

              <div style={{ marginBottom: '12px' }}>
                <button
                  type="button"
                  onClick={() => {
                    setReasigUnidadId(String(ACTORES_FOUNDRY.dianaRecupero.uf));
                    setReasigNuevaAddr(ACTORES_FOUNDRY.dianaRecupero.address);
                    setReasigDniEmail(ACTORES_FOUNDRY.dianaRecupero.dniEmail);
                  }}
                  style={{
                    background: 'rgba(245, 158, 11, 0.2)',
                    border: '1px solid rgba(245, 158, 11, 0.5)',
                    color: '#fde68a',
                    padding: '5px 10px',
                    borderRadius: '6px',
                    fontSize: '0.75rem',
                    cursor: 'pointer',
                    fontWeight: 600,
                    width: '100%',
                  }}
                >
                  ⚡ Cargar Caso Prueba: Recupero de Billetera de Titular UF 104
                </button>
              </div>

              <form onSubmit={handleReasignarUnidad}>
                <div className="form-group">
                  <label>Unidad Funcional a Reasignar (<code>unidadId</code>):</label>
                  <input
                    type="number"
                    className="form-input"
                    placeholder="Ej. 104"
                    value={reasigUnidadId}
                    onChange={(e) => setReasigUnidadId(e.target.value)}
                    required
                  />
                </div>
                <div className="form-group">
                  <label>Nueva Billetera Verificada (<code>nuevoPropietario</code>):</label>
                  <input
                    type="text"
                    className="form-input mono"
                    placeholder="0x..."
                    value={reasigNuevaAddr}
                    onChange={(e) => setReasigNuevaAddr(e.target.value)}
                    required
                  />
                </div>
                <div className="form-group">
                  <label>Verificación Administrativa Previa (DNI + Email / Escritura):</label>
                  <input
                    type="text"
                    className="form-input"
                    placeholder="Ej. DNI 28456789 - vecino@consorcio.com"
                    value={reasigDniEmail}
                    onChange={(e) => setReasigDniEmail(e.target.value)}
                  />
                  {identidadHashPreview && (
                    <div className="mono" style={{ marginTop: '6px', fontSize: '0.73rem', color: '#38bdf8', wordBreak: 'break-all' }}>
                      🔐 Hash Identidad (keccak256): {identidadHashPreview}
                    </div>
                  )}
                </div>
                <button
                  className="action-btn"
                  type="submit"
                  disabled={loading}
                  style={{ background: 'linear-gradient(135deg, #f59e0b 0%, #d97706 100%)', color: '#000', fontWeight: 700 }}
                >
                  {loading ? 'Reasignando NFT...' : '🔄 Reasignar Unidad y Recuperar Voto'}
                </button>
              </form>
            </div>

            {/* CASO 4: Inquilino Vota en Asambleas */}
            <div className="card">
              <h2>4️⃣ Delegar Voto a Inquilino (<code>delegate</code>)</h2>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.82rem', marginBottom: '12px' }}>
                El propietario <strong>conserva su NFT Soulbound intransferible</strong>, pero le cede temporalmente el poder de voto en asambleas a su inquilino (o lo recupera cuando quiere).
              </p>

              <div style={{ marginBottom: '12px' }}>
                <button
                  type="button"
                  onClick={() => setDelegateTargetAddr(ACTORES_FOUNDRY.inquilinoLeo.address)}
                  style={{
                    background: 'rgba(168, 85, 247, 0.22)',
                    border: '1px solid rgba(168, 85, 247, 0.5)',
                    color: '#f3e8ff',
                    padding: '5px 10px',
                    borderRadius: '6px',
                    fontSize: '0.75rem',
                    cursor: 'pointer',
                    fontWeight: 600,
                    width: '100%',
                  }}
                >
                  ⚡ Cargar Billetera de Locatario / Delegatario ({ACTORES_FOUNDRY.inquilinoLeo.address.slice(0, 6)}...{ACTORES_FOUNDRY.inquilinoLeo.address.slice(-4)})
                </button>
              </div>

              <div style={{ marginBottom: '14px', padding: '10px 12px', background: 'rgba(168, 85, 247, 0.12)', border: '1px solid rgba(168, 85, 247, 0.35)', borderRadius: '8px', fontSize: '0.8rem' }}>
                <div><strong>Tus NFTs de Propiedad:</strong> {userNftBalance} Unidad(es)</div>
                <div style={{ marginTop: '4px' }}>
                  <strong>Tu Delegatario Actual:</strong>{' '}
                  <span className="mono">
                    {userDelegatee === ethers.ZeroAddress
                      ? 'Sin delegar'
                      : `${userDelegatee.slice(0, 6)}...${userDelegatee.slice(-4)}`}
                  </span>
                  {account && userDelegatee.toLowerCase() === account.toLowerCase() && (
                    <span className="badge badge-success" style={{ marginLeft: '6px' }}>Tú mismo</span>
                  )}
                  {account && userDelegatee !== ethers.ZeroAddress && userDelegatee.toLowerCase() !== account.toLowerCase() && (
                    <span className="badge badge-info" style={{ marginLeft: '6px' }}>Inquilino Activo</span>
                  )}
                </div>
              </div>

              <div className="form-group">
                <label>Billetera del Inquilino o Representante (<code>billeteraInquilino</code>):</label>
                <input
                  type="text"
                  className="form-input mono"
                  placeholder="0x... (Billetera del Inquilino)"
                  value={delegateTargetAddr}
                  onChange={(e) => setDelegateTargetAddr(e.target.value)}
                />
              </div>

              <button
                type="button"
                className="action-btn"
                disabled={loading || !delegateTargetAddr.trim()}
                onClick={() => handleDelegarVoto(delegateTargetAddr)}
                style={{ marginBottom: '10px' }}
              >
                {loading ? 'Delegando...' : '🔑 Ceder Poder de Voto al Inquilino'}
              </button>

              <button
                type="button"
                className="action-btn"
                disabled={loading || !account}
                onClick={() => handleDelegarVoto(account)}
                style={{ background: 'linear-gradient(135deg, #10b981 0%, #059669 100%)' }}
              >
                🔄 Recuperar mi Voto (Auto-delegarme a mi Billetera)
              </button>
            </div>
          </div>
        </div>
      )}

      {/* =====================================================================
          CASO 3: PESTAÑA PAGAR EXPENSAS (CON CORRECCIÓN DOCENTE PUNTO 3)
         ===================================================================== */}
      {activeTab === 'pagar' && (
        <div className="card" style={{ maxWidth: '640px', margin: '0 auto' }}>
          <h2>3️⃣ Pago de Expensas al Vault (Propietario o Inquilino)</h2>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.84rem', marginBottom: '16px' }}>
            [Corrección Docente Punto 3] <code>ConsorcioObras.sol</code> valida on-chain que <code>consorcioVotes.propietarioDeUnidad(unidadId) != address(0)</code> (revirtiendo con <code>UnidadNoAdjudicada</code> si el lote no existe), y permite que tanto el dueño como el inquilino abonen las expensas de una unidad adjudicada (Art. 881 CCyC).
          </p>

          <form onSubmit={handlePagarExpensas}>
            <div className="form-group">
              <label>Número de Unidad Funcional o Lote (<code>unidadId</code>):</label>
              <input
                type="number"
                className="form-input"
                placeholder="Ej. 101"
                value={pagoUnidadId}
                onChange={(e) => setPagoUnidadId(e.target.value)}
                required
              />
            </div>

            {pagoUnidadDetalle && (
              <div style={{ marginBottom: '16px', padding: '12px 14px', background: 'rgba(15, 23, 42, 0.85)', border: '1px solid rgba(56, 189, 248, 0.45)', borderRadius: '10px', fontSize: '0.84rem' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '6px' }}>
                  <strong>📋 Estado Contable de Unidad #{pagoUnidadDetalle.unidadId}</strong>
                  {pagoUnidadDetalle.propietario === ethers.ZeroAddress ? (
                    <span className="badge badge-danger">🚫 Unidad NO Adjudicada (Revertirá con UnidadNoAdjudicada)</span>
                  ) : account && pagoUnidadDetalle.propietario.toLowerCase() === account.toLowerCase() ? (
                    <span className="badge badge-success">🏠 Pagando como Propietario Titular</span>
                  ) : (
                    <span className="badge badge-info">🔑 Pagando como Inquilino / Tercero</span>
                  )}
                </div>
                <div style={{ color: 'var(--text-muted)', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px', marginTop: '8px' }}>
                  <div>
                    Titular del NFT:{' '}
                    <span className="mono" style={{ color: '#f8fafc' }}>
                      {pagoUnidadDetalle.propietario === ethers.ZeroAddress
                        ? 'No adjudicado (address(0))'
                        : `${pagoUnidadDetalle.propietario.slice(0, 6)}...${pagoUnidadDetalle.propietario.slice(-4)}`}
                    </span>
                  </div>
                  <div>
                    Acumulado Histórico:{' '}
                    <strong style={{ color: '#38bdf8' }}>{parseFloat(pagoUnidadDetalle.expensasPagadas).toFixed(4)} ETH</strong>
                  </div>
                </div>
              </div>
            )}

            <div className="form-group">
              <label>Importe a Abonar (ETH en Sepolia):</label>
              <input
                type="number"
                step="0.0001"
                className="form-input"
                placeholder="Ej. 0.001"
                value={pagoMonto}
                onChange={(e) => setPagoMonto(e.target.value)}
                required
              />
            </div>
            <div className="form-group">
              <label>Concepto / Detalle del Período:</label>
              <input
                type="text"
                className="form-input"
                placeholder="Ej. Expensas Octubre 2026 - Abonado por Inquilino Lote 102"
                value={pagoConcepto}
                onChange={(e) => setPagoConcepto(e.target.value)}
              />
            </div>
            <button className="action-btn" type="submit" disabled={loading}>
              {loading ? 'Procesando en MetaMask...' : '💳 Abonar Expensas e Imputar al Lote'}
            </button>
          </form>
        </div>
      )}

      {/* =====================================================================
          PESTAÑA GOBERNANZA Y VOTACIÓN (INCLUYE CORRECCIÓN DOCENTE PUNTOS 1 Y 5)
         ===================================================================== */}
      {activeTab === 'gobernanza' && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(420px, 1fr))', gap: '20px' }}>
          <div className="card">
            <h2>Crear Propuesta de Asamblea (Governor V2 — Quórum {governorQuorumPct}%)</h2>
            <form onSubmit={handleCrearPropuesta}>
              <div className="form-group">
                <label>Tipo de Decisión de Asamblea:</label>
                <select
                  className="form-input"
                  value={propTipo}
                  onChange={(e) => setPropTipo(e.target.value)}
                >
                  <option value="nuevaObra">Crear Nueva Obra (Aprobar y Liberar Hito 1 - 30%)</option>
                  <option value="liberarHito2">Liberar Hito 2 (40% de Avance - Obra Existente)</option>
                  <option value="liberarHito3">Liquidación Final Hito 3 (30% Entrega Definitiva)</option>
                </select>
              </div>

              {propTipo !== 'nuevaObra' ? (
                <>
                  <div className="form-group">
                    <label>Seleccionar Obra Registrada:</label>
                    <select
                      className="form-input"
                      value={propObraId}
                      onChange={(e) => setPropObraId(e.target.value)}
                    >
                      {obrasList.length === 0 ? (
                        <option value="1">Obra #1</option>
                      ) : (
                        obrasList.map((o) => (
                          <option key={o.id} value={o.id}>
                            #{o.id} - {o.nombre} ({ESTADO_OBRA_NOMBRES[o.estado] || o.estado})
                          </option>
                        ))
                      )}
                    </select>
                  </div>
                </>
              ) : (
                <>
                  <div className="form-group">
                    <label>Nombre de la Obra:</label>
                    <input
                      type="text"
                      className="form-input"
                      value={propNombre}
                      onChange={(e) => setPropNombre(e.target.value)}
                      required
                    />
                  </div>
                  <div className="form-group">
                    <label>Descripción / Pliego Técnico:</label>
                    <input
                      type="text"
                      className="form-input"
                      value={propDesc}
                      onChange={(e) => setPropDesc(e.target.value)}
                      required
                    />
                  </div>
                  <div className="form-group">
                    <label>Billetera del Contratista o Administrador:</label>
                    <input
                      type="text"
                      className="form-input mono"
                      value={propContratista}
                      onChange={(e) => setPropContratista(e.target.value)}
                      required
                    />
                  </div>
                  <div className="form-group">
                    <label>Presupuesto Total (ETH):</label>
                    <input
                      type="number"
                      step="0.0001"
                      className="form-input"
                      value={propPresupuesto}
                      onChange={(e) => setPropPresupuesto(e.target.value)}
                      required
                    />
                  </div>
                </>
              )}

              <button className="action-btn" type="submit" disabled={loading}>
                {loading ? 'Firmando Propuesta...' : '🗳️ Crear Propuesta On-Chain'}
              </button>
            </form>
          </div>

          <div className="card">
            <h2>Votar, Encolar o Cancelar en Ventana de Seguridad</h2>
            <form onSubmit={handleVotar}>
              <div className="form-group">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '6px' }}>
                  <label style={{ margin: 0 }}>Proposal ID:</label>
                  {localStorage.getItem('last_active_proposal_id') && (
                    <button
                      type="button"
                      onClick={() => setPropIdVote(localStorage.getItem('last_active_proposal_id'))}
                      style={{ background: 'transparent', border: 'none', color: '#38bdf8', fontSize: '0.78rem', cursor: 'pointer', textDecoration: 'underline' }}
                    >
                      📋 Cargar Última Propuesta Creada
                    </button>
                  )}
                </div>
                <input
                  type="text"
                  className="form-input mono"
                  value={propIdVote}
                  onChange={(e) => {
                    setPropIdVote(e.target.value);
                    try { localStorage.setItem('last_active_proposal_id', e.target.value); } catch (_) {}
                  }}
                  required
                />

                {proposalStateInfo !== null && (
                  <div style={{ marginTop: '10px' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '6px' }}>
                      <span style={{ fontSize: '0.85rem', color: 'var(--text-muted)' }}>Estado on-chain:</span>
                      <span className={`badge ${proposalStateInfo === 1 ? 'badge-success' : proposalStateInfo === 4 || proposalStateInfo === 7 ? 'badge-info' : proposalStateInfo === 0 || proposalStateInfo === 5 ? 'badge-warning' : 'badge-danger'}`}>
                        {ESTADO_PROPUESTA_NOMBRES[proposalStateInfo] || 'Desconocido'}
                      </span>
                    </div>

                    {proposalStateInfo === 0 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(245, 158, 11, 0.2)', border: '1px solid #f59e0b', borderRadius: '8px', fontSize: '0.82rem', color: '#fde047' }}>
                        ⏳ <strong>Deliberación Previa (Pending):</strong> La votación abrirá tras el votingDelay (10s). ¡Ya puedes ir firmando votos Gasless EIP-712 abajo!
                      </div>
                    )}

                    {proposalStateInfo === 1 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(16, 185, 129, 0.25)', border: '2px solid #10b981', borderRadius: '8px', fontSize: '0.84rem', color: '#6ee7b7', fontWeight: 600 }}>
                        🟢 <strong>¡ASAMBLEA ABIERTA PARA VOTAR!</strong> Con Quórum del {governorQuorumPct}%, emite los votos a favor ahora.
                      </div>
                    )}

                    {proposalStateInfo === 2 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(239, 68, 68, 0.2)', border: '1px solid #ef4444', borderRadius: '8px', fontSize: '0.82rem', color: '#fca5a5' }}>
                        🛑 <strong>Propuesta Cancelada (Canceled):</strong> La operación fue revocada en el Governor y en el Timelock.
                      </div>
                    )}

                    {proposalStateInfo === 3 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(239, 68, 68, 0.2)', border: '1px solid #ef4444', borderRadius: '8px', fontSize: '0.82rem', color: '#fca5a5' }}>
                        ⌛ <strong>Votación No Aprobada (Defeated):</strong> No se alcanzó el quórum del {governorQuorumPct}% o mayoría.
                      </div>
                    )}

                    {proposalStateInfo === 4 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(37, 99, 235, 0.2)', border: '1px solid #3b82f6', borderRadius: '8px', fontSize: '0.82rem', color: '#93c5fd' }}>
                        🎉 <strong>¡Propuesta Aprobada (Succeeded)!</strong> Lista para ser encolada en el Timelock con el botón de abajo.
                      </div>
                    )}

                    {proposalStateInfo === 7 && (
                      <div style={{ padding: '10px 12px', background: 'rgba(16, 185, 129, 0.2)', border: '1px solid #10b981', borderRadius: '8px', fontSize: '0.82rem', color: '#a7f3d0' }}>
                        ✅ <strong>Propuesta Ejecutada:</strong> Esta propuesta ya fue aplicada on-chain en el contrato.
                      </div>
                    )}
                  </div>
                )}
              </div>

              <div className="form-group">
                <label>Sentido del Voto:</label>
                <select
                  className="form-input"
                  value={voteSupport}
                  onChange={(e) => setVoteSupport(e.target.value)}
                >
                  <option value="1">1 - A Favor (For)</option>
                  <option value="0">0 - En Contra (Against)</option>
                  <option value="2">2 - Abstención (Abstain)</option>
                </select>
              </div>

              <button
                className="action-btn"
                type="submit"
                disabled={loading || proposalStateInfo !== 1}
                style={proposalStateInfo === 1 ? { background: 'linear-gradient(135deg, #10b981 0%, #059669 100%)', borderColor: '#34d399' } : {}}
              >
                {loading ? 'Emitiendo Voto...' : proposalStateInfo === 1 ? '✍️ Emitir Voto Directo On-Chain (castVote)' : '⏳ Votación no abierta'}
              </button>
            </form>

            {/* CASO 5: VOTACIÓN GASLESS POR FIRMA EIP-712 */}
            <div style={{ marginTop: '20px', padding: '16px', background: 'rgba(15, 23, 42, 0.88)', border: '1px solid rgba(168, 85, 247, 0.5)', borderRadius: '10px' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '8px' }}>
                <h3 style={{ fontSize: '0.96rem', color: '#d8b4fe', margin: 0 }}>
                  5️⃣ ⚡ Votación Gasless por Firma EIP-712 (<code>castVoteBySig</code>)
                </h3>
                <span className="badge badge-info">0 Gas para el Vecino</span>
              </div>

              <div style={{ marginBottom: '12px' }}>
                <div style={{ fontSize: '0.76rem', color: '#e9d5ff', marginBottom: '6px', fontWeight: 600 }}>
                  🖋️ Paso 1 (0 Gas): Elige quién firma el cupón EIP-712 Off-Chain:
                </div>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px', marginBottom: '8px' }}>
                  {[
                    ACTORES_FOUNDRY.bob,
                    ACTORES_FOUNDRY.carlos,
                    ACTORES_FOUNDRY.diana,
                    ACTORES_FOUNDRY.dianaRecupero,
                    ACTORES_FOUNDRY.inquilinoLeo,
                  ].map((act) => (
                    <button
                      key={act.address}
                      type="button"
                      disabled={loading || !propIdVote}
                      onClick={() => handleFirmarVotoGasless(act)}
                      style={{
                        background: 'rgba(147, 51, 234, 0.28)',
                        border: '1px solid rgba(168, 85, 247, 0.6)',
                        color: '#f3e8ff',
                        padding: '6px 10px',
                        borderRadius: '6px',
                        fontSize: '0.75rem',
                        cursor: !propIdVote ? 'not-allowed' : 'pointer',
                        fontWeight: 600,
                      }}
                    >
                      ⚡ Firmar como {act.nombre}
                    </button>
                  ))}
                </div>
              </div>

              {sigData && (
                <div style={{ marginBottom: '12px', padding: '10px', background: 'rgba(168, 85, 247, 0.12)', border: '1px dashed #a855f7', borderRadius: '8px', fontSize: '0.76rem' }}>
                  <div style={{ color: '#e9d5ff', fontWeight: 600, marginBottom: '4px' }}>
                    ✅ Cupón EIP-712 Firmado (Nonce #{sigData.nonce}):
                  </div>
                  <div className="mono" style={{ wordBreak: 'break-all', color: '#cbd5e1' }}>
                    Voter: {sigData.voter} | Support: {sigData.support} | Sig: {sigData.signature.slice(0, 26)}...{sigData.signature.slice(-16)}
                  </div>
                </div>
              )}

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px', marginBottom: '8px' }}>
                <div>
                  <label style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>Billetera Votante (<code>voter</code>):</label>
                  <input
                    type="text"
                    className="form-input mono"
                    style={{ padding: '6px 8px', fontSize: '0.78rem' }}
                    value={manualSigVoter}
                    onChange={(e) => setManualSigVoter(e.target.value)}
                  />
                </div>
                <div>
                  <label style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>Firma EIP-712 (<code>signature</code>):</label>
                  <input
                    type="text"
                    className="form-input mono"
                    style={{ padding: '6px 8px', fontSize: '0.78rem' }}
                    value={manualSigHex}
                    onChange={(e) => setManualSigHex(e.target.value)}
                  />
                </div>
              </div>

              <button
                type="button"
                className="action-btn"
                disabled={loading || !manualSigHex || proposalStateInfo !== 1}
                onClick={handleEnviarVotoPorFirma}
                style={proposalStateInfo === 1 && manualSigHex ? { background: 'linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%)' } : {}}
              >
                🚀 Paso 2 (Relayer / Admin): Enviar Voto Firmado al Contrato (castVoteBySig)
              </button>
            </div>

            {/* Encolar, Cancelar en Ventana de Seguridad o Ejecutar en Timelock */}
            {proposalStateInfo === 4 && (
              <div style={{ marginTop: '16px', paddingTop: '16px', borderTop: '1px solid var(--border)' }}>
                <button
                  className="action-btn"
                  onClick={handleEncolarPropuesta}
                  disabled={loading || !timelockSellado}
                >
                  ⏳ 1. Encolar Propuesta en Timelock (Queue)
                </button>
              </div>
            )}

            {proposalStateInfo === 5 && (
              <div style={{ marginTop: '16px', paddingTop: '16px', borderTop: '1px solid var(--border)', display: 'flex', flexDirection: 'column', gap: '10px' }}>
                <p style={{ fontSize: '0.84rem', color: 'var(--text-muted)', margin: 0 }}>
                  🕒 La propuesta está <strong>Encolada (Queued)</strong> en la ventana de seguridad del Timelock (60 seg). Puedes ejecutarla vencido el plazo, o cancelarla de emergencia (<strong>Corrección Docente Punto 5</strong>):
                </p>
                <button
                  className="action-btn"
                  onClick={handleEjecutarPropuesta}
                  disabled={loading}
                >
                  🚀 2A. Ejecutar Propuesta en Timelock (Execute tras 60s)
                </button>
                <button
                  type="button"
                  className="action-btn"
                  onClick={handleCancelarPropuestaEnCola}
                  disabled={loading}
                  style={{ background: 'linear-gradient(135deg, #ef4444 0%, #b91c1c 100%)' }}
                >
                  🛑 2B. Cancelar Propuesta Encolada en Ventana de Seguridad (cancelarPropuestaEnCola)
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Pestaña: Rendición de Cuentas */}
      {activeTab === 'rendir' && (
        <div className="card" style={{ maxWidth: '650px', margin: '0 auto' }}>
          <h2>Rendición de Cuentas por Hito (IPFS)</h2>
          <div style={{ marginBottom: '20px', padding: '16px', background: 'rgba(37, 99, 235, 0.1)', border: '1px dashed #3b82f6', borderRadius: '10px' }}>
            <h3 style={{ fontSize: '1rem', color: '#60a5fa', marginBottom: '6px' }}>
              📤 Cargar Factura o Comprobante a IPFS (Pinata)
            </h3>
            <input
              type="file"
              accept="application/pdf,image/*,application/json,.txt"
              onChange={handleUploadFileToPinata}
              disabled={uploadingIpfs || loading}
              style={{
                display: 'block',
                width: '100%',
                padding: '8px 12px',
                border: '1px solid var(--card-border)',
                borderRadius: '8px',
                background: 'var(--bg)',
                color: 'var(--text)',
                cursor: 'pointer',
              }}
            />
          </div>

          <form onSubmit={handleRendirCuentas}>
            <div className="form-group">
              <label>ID de la Obra:</label>
              <input
                type="number"
                className="form-input"
                value={rendicionObraId}
                onChange={(e) => setRendicionObraId(e.target.value)}
                required
              />
            </div>
            <div className="form-group">
              <label>Hito que se rinde:</label>
              <select
                className="form-input"
                value={rendicionHitoNum}
                onChange={(e) => setRendicionHitoNum(e.target.value)}
              >
                <option value="1">Hito 1 (Anticipo 30%)</option>
                <option value="2">Hito 2 (Avance 40%)</option>
              </select>
            </div>
            <div className="form-group">
              <label>Hash IPFS / URI con Facturas y Fotos de Avance:</label>
              <input
                type="text"
                className="form-input mono"
                value={rendicionCid}
                onChange={(e) => setRendicionCid(e.target.value)}
                required
              />
            </div>
            <button className="action-btn" type="submit" disabled={loading || uploadingIpfs}>
              {loading ? 'Registrando en Blockchain...' : '📑 Asentar Rendición On-Chain'}
            </button>
          </form>
        </div>
      )}

      {/* Pestaña: Contratos en Etherscan */}
      {activeTab === 'contratos' && (
        <div className="card">
          <h2>Contratos V2 del Protocolo en Sepolia Etherscan</h2>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Contrato</th>
                  <th>Dirección Activa en Sepolia</th>
                  <th>Mejoras V2 Implementadas</th>
                  <th>Link Etherscan</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td><strong>ConsorcioVotes</strong></td>
                  <td className="mono">{activeAddresses.ConsorcioVotes}</td>
                  <td>ERC721Votes + Ownable2Step + Doble Vía <code>onlyRegistradorOrOwner</code> (Punto 6)</td>
                  <td>
                    <a className="etherscan-link" href={`${ETHERSCAN_BASE_URL}/address/${activeAddresses.ConsorcioVotes}#code`} target="_blank" rel="noreferrer">
                      Ver en Etherscan ↗
                    </a>
                  </td>
                </tr>
                <tr>
                  <td><strong>ConsorcioTimelock</strong></td>
                  <td className="mono">{activeAddresses.ConsorcioTimelock}</td>
                  <td>TimelockController + Sellado Atómico + <code>CANCELLER_ROLE</code> (Punto 5)</td>
                  <td>
                    <a className="etherscan-link" href={`${ETHERSCAN_BASE_URL}/address/${activeAddresses.ConsorcioTimelock}#code`} target="_blank" rel="noreferrer">
                      Ver en Etherscan ↗
                    </a>
                  </td>
                </tr>
                <tr>
                  <td><strong>ConsorcioGovernor</strong></td>
                  <td className="mono">{activeAddresses.ConsorcioGovernor}</td>
                  <td>Quórum Estatutario 50% (Mín 30%, Punto 1) + <code>cancelarPropuestaEnCola</code> (Punto 5)</td>
                  <td>
                    <a className="etherscan-link" href={`${ETHERSCAN_BASE_URL}/address/${activeAddresses.ConsorcioGovernor}#code`} target="_blank" rel="noreferrer">
                      Ver en Etherscan ↗
                    </a>
                  </td>
                </tr>
                <tr>
                  <td><strong>ConsorcioObras</strong></td>
                  <td className="mono">{activeAddresses.ConsorcioObras}</td>
                  <td>Esquema Híbrido Push+Pull (Punto 2) + Validación <code>UnidadNoAdjudicada</code> (Punto 3)</td>
                  <td>
                    <a className="etherscan-link" href={`${ETHERSCAN_BASE_URL}/address/${activeAddresses.ConsorcioObras}#code`} target="_blank" rel="noreferrer">
                      Ver en Etherscan ↗
                    </a>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
