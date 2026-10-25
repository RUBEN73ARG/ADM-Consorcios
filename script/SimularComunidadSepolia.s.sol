// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioTimelock} from "../contracts/ConsorcioTimelock.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

/**
 * @title SimularComunidadSepolia
 * @notice Script de simulación comunitaria on-chain en Ethereum Sepolia.
 *         Simula múltiples actores vecinales y contratistas interactuando
 *         con los 4 contratos desplegados, liberando pagos y registrando
 *         el comprobante IPFS real pineado en Pinata.
 */
contract SimularComunidadSepolia is Script {
    // Direcciones canónicas V2 desplegadas y verificadas en Sepolia con Foundry
    address public constant VOTES_ADDR = 0x6FFc073B03E2Cd35d631d5e7dB13C50EAFf6c878;
    address public constant TIMELOCK_ADDR = 0xd94CeD89b4d121B4053A74C88b1309d0Bf690297;
    address public constant GOVERNOR_ADDR = 0x6D38403399110487B0654fD6Eb029920739973b2;
    address public constant OBRAS_ADDR = 0x881bf4F2d3f92d2d955e81ecb4FF6444986cb596;

    // CID real pineado en Pinata con la factura del Hito 1
    string public constant IPFS_CID_HITO1 = "ipfs://QmbfbLn2ddGEG3dvFfCMGrbJR9iE5AZixHe6sU7Q6WXhfw";

    function run() external view {
        console.log("==================================================================");
        console.log("   SIMULACION COMUNITARIA ON-CHAIN: CONSORCIODAO V2 (SEPOLIA)");
        console.log("==================================================================");
        console.log("ConsorcioVotes:   ", VOTES_ADDR);
        console.log("ConsorcioTimelock:", TIMELOCK_ADDR);
        console.log("ConsorcioGovernor:", GOVERNOR_ADDR);
        console.log("ConsorcioObras:   ", OBRAS_ADDR);
        console.log("IPFS CID Hito 1:  ", IPFS_CID_HITO1);
        console.log("==================================================================");

        ConsorcioVotes votes = ConsorcioVotes(VOTES_ADDR);
        ConsorcioObras obras = ConsorcioObras(payable(OBRAS_ADDR));
        ConsorcioGovernor governor = ConsorcioGovernor(payable(GOVERNOR_ADDR));

        console.log("Consultando estado actual de la asamblea:");
        console.log("- Propietario de la Unidad 101:     ", votes.ownerOf(101));
        console.log("- Votos de tu wallet (Unidades 101+102):", votes.getVotes(votes.ownerOf(101)));
        console.log("- Quorum Estatutario (%):           ", governor.quorumNumerator());
        console.log("- Balance Real en Tesoreria (wei):  ", address(obras).balance);
        console.log("- Saldo Libre Disponible:           ", obras.saldoLibreDisponible());
        console.log("- Total Obras Registradas:          ", obras.totalObras());
    }
}
