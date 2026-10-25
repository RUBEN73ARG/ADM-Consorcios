import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

const env = loadEnv('development', process.cwd(), '');
const SEPOLIA_RPCS = [
  env.VITE_ALCHEMY_SEPOLIA_RPC_URL,
  'https://ethereum-sepolia-rpc.publicnode.com',
  'https://1rpc.io/sepolia',
].filter(Boolean);

function foundryMetaMaskBridge() {
  let pendingQueue = [];
  let nextQueueId = 1;

  async function forwardToSepolia(payload) {
    let lastErr;
    for (const url of SEPOLIA_RPCS) {
      try {
        const resp = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (resp.ok) {
          return await resp.json();
        }
      } catch (err) {
        lastErr = err;
      }
    }
    throw lastErr || new Error('All Sepolia RPCs failed');
  }

  async function handleSingleRpc(reqObj) {
    const { id, method, params } = reqObj;
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') {
      return {
        jsonrpc: '2.0',
        id,
        result: ['0x3b9DE69C652f54582155372d45bB176e810eEEA1'],
      };
    }
    if (method === 'eth_sendTransaction') {
      const tx = { ...((params && params[0]) || {}) };
      // Garantizar piso mínimo de gas para el protocolo Osaka en Sepolia
      const currentGas = tx.gas ? parseInt(tx.gas, 16) : 0;
      if (tx.to) {
        if (currentGas < 2500000) {
          tx.gas = '0x2625a0'; // 2,500,000 gas mínimo para llamadas en Osaka
        }
      } else {
        if (currentGas < 15000000) {
          tx.gas = '0xe4e1c0'; // 15,000,000 gas mínimo para deploys en Osaka
        }
      }
      const queueId = nextQueueId++;
      return await new Promise((resolve) => {
        pendingQueue.push({
          queueId,
          rpcId: id,
          tx,
          dispatched: false,
          resolve,
        });
      });
    }
    if (method === 'eth_estimateGas') {
      const resp = await forwardToSepolia(reqObj);
      if (resp && resp.result) {
        const est = parseInt(resp.result, 16);
        if (!Number.isNaN(est) && est > 0) {
          const boosted = Math.min(35000000, Math.max(est * 3, 2500000));
          resp.result = '0x' + boosted.toString(16);
        }
      }
      return resp;
    }
    if (method === 'eth_getTransactionReceipt') {
      const resp = await forwardToSepolia(reqObj);
      if (resp && resp.result && resp.result.blockNumber) {
        // Pausa de sincronización de 2.5s para que el nodo RPC interno de MetaMask
        // indexe el bloque recién minado antes de recibir la siguiente transacción de Foundry
        await new Promise((r) => setTimeout(r, 2500));
      }
      return resp;
    }
    return await forwardToSepolia(reqObj);
  }

  return {
    name: 'foundry-metamask-bridge',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        if (!req.url) return next();

        // Neutralizar cualquier pestaña antigua que siga consultando /rpc-pending
        if (req.url === '/rpc-pending' && req.method === 'GET') {
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ pending: null }));
          return;
        }

        if (req.url.startsWith('/rpc-pending-v2') && req.method === 'GET') {
          const item = pendingQueue.find((q) => !q.dispatched);
          if (item) {
            item.dispatched = true;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ pending: { queueId: item.queueId, tx: item.tx } }));
          } else {
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ pending: null }));
          }
          return;
        }

        if (req.url.startsWith('/rpc-result-v2') && req.method === 'POST') {
          let body = '';
          req.on('data', (chunk) => { body += chunk; });
          req.on('end', () => {
            try {
              const { queueId, result, error } = JSON.parse(body);
              const idx = pendingQueue.findIndex((q) => q.queueId === queueId);
              if (idx !== -1) {
                const item = pendingQueue[idx];
                pendingQueue.splice(idx, 1);
                if (error) {
                  item.resolve({
                    jsonrpc: '2.0',
                    id: item.rpcId,
                    error: { code: -32000, message: String(error) },
                  });
                } else {
                  item.resolve({
                    jsonrpc: '2.0',
                    id: item.rpcId,
                    result,
                  });
                }
              }
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.statusCode = 400;
              res.end(JSON.stringify({ error: e.message }));
            }
          });
          return;
        }

        if (req.url === '/rpc' && req.method === 'POST') {
          let body = '';
          req.on('data', (chunk) => { body += chunk; });
          req.on('end', async () => {
            try {
              const parsed = JSON.parse(body);
              let responsePayload;
              if (Array.isArray(parsed)) {
                responsePayload = await Promise.all(parsed.map((item) => handleSingleRpc(item)));
              } else {
                responsePayload = await handleSingleRpc(parsed);
              }
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify(responsePayload));
            } catch (e) {
              res.statusCode = 500;
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32603, message: e.message } }));
            }
          });
          return;
        }

        next();
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), foundryMetaMaskBridge()],
  base: './',
  server: { host: true, port: 5173, open: true },
  preview: { host: true, port: 4173, open: true },
  build: { target: 'es2020', sourcemap: false },
});
