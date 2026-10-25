// Configuración centralizada de contratos V2 desplegados en Sepolia, nodo RPC Alchemy, Etherscan y Pinata IPFS
export const SEPOLIA_CHAIN_ID = '0xaa36a7'; // 11155111 en hexadecimal
export const SEPOLIA_DECIMAL_CHAIN_ID = 11155111;

// Direcciones de los 4 Smart Contracts V2 desplegados y verificados en Ethereum Sepolia
export const CONTRACT_ADDRESSES = {
  ConsorcioVotes: '0x6FFc073B03E2Cd35d631d5e7dB13C50EAFf6c878',
  ConsorcioTimelock: '0xd94CeD89b4d121B4053A74C88b1309d0Bf690297',
  ConsorcioGovernor: '0x6D38403399110487B0654fD6Eb029920739973b2',
  ConsorcioObras: '0x881bf4F2d3f92d2d955e81ecb4FF6444986cb596',
};

// Integración con Nodo RPC de Alchemy, Etherscan API y Pinata IPFS (inyectados desde variables de entorno .env)
export const ALCHEMY_SEPOLIA_RPC_URL = import.meta.env.VITE_ALCHEMY_SEPOLIA_RPC_URL || '';
export const ETHERSCAN_API_KEY = import.meta.env.VITE_ETHERSCAN_API_KEY || '';
export const ETHERSCAN_BASE_URL = 'https://sepolia.etherscan.io';

export const ESTADO_OBRA_NOMBRES = [
  'Inexistente',
  'Aprobada (Pendiente Hito 1)',
  'Hito 1 Liberado (30%)',
  'Hito 1 Rendido en IPFS',
  'Hito 2 Liberado (40%)',
  'Hito 2 Rendido en IPFS',
  'Finalizada (Liquidada 100%)',
  'Cancelada'
];

export const ESTADO_PROPUESTA_NOMBRES = [
  'Pendiente',
  'Activa (Votación abierta)',
  'Cancelada',
  'Derrotada',
  'Aprobada (Succeeded)',
  'Encolada (Queued)',
  'Vencida',
  'Ejecutada'
];

export const PINATA_GATEWAY_URL = 'https://gateway.pinata.cloud/ipfs';
export const DEFAULT_PINATA_JWT = import.meta.env.VITE_PINATA_JWT || '';


