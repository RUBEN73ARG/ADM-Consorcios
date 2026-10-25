// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ConsorcioVotes} from "../contracts/ConsorcioVotes.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";

/**
 * @title FirmarVotosFoundry
 * @notice Genera firmas EIP-712 (castVoteBySig) desde Foundry usando vm.sign
 *         para los actores de la comunidad (Bob, Carlos, Diana, Diana Recupero e Inquilino Leo).
 */
contract FirmarVotosFoundry is Script {
    address public constant VOTES_ADDR = 0x6FFc073B03E2Cd35d631d5e7dB13C50EAFf6c878;
    address public constant GOVERNOR_ADDR = 0x6D38403399110487B0654fD6Eb029920739973b2;

    uint256 public constant PK_BOB = 0x102;
    uint256 public constant PK_CARLOS = 0x103;
    uint256 public constant PK_DIANA = 0x104;
    uint256 public constant PK_DIANA_RECUPERO = 0x204;
    uint256 public constant PK_INQUILINO_LEO = 0x302;

    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)");

    function run(uint256 proposalId, uint8 support) external view {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ConsorcioGovernor")),
                keccak256(bytes("1")),
                uint256(11155111),
                GOVERNOR_ADDR
            )
        );

        _imprimirFirma("Bob (UF 102)", PK_BOB, proposalId, support, domainSeparator);
        _imprimirFirma("Carlos (UF 103)", PK_CARLOS, proposalId, support, domainSeparator);
        _imprimirFirma("Diana (UF 104)", PK_DIANA, proposalId, support, domainSeparator);
        _imprimirFirma("Diana Recupero (UF 104)", PK_DIANA_RECUPERO, proposalId, support, domainSeparator);
        _imprimirFirma("Inquilino Leo", PK_INQUILINO_LEO, proposalId, support, domainSeparator);
    }

    function _imprimirFirma(
        string memory nombre,
        uint256 pk,
        uint256 proposalId,
        uint8 support,
        bytes32 domainSeparator
    ) internal view {
        address voter = vm.addr(pk);
        uint256 nonce = ConsorcioGovernor(payable(GOVERNOR_ADDR)).nonces(voter);
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support, voter, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        console.log("------------------------------------------------------------------");
        console.log("Actor:", nombre);
        console.log("Voter Address:", voter);
        console.log("Votos Activos:", ConsorcioVotes(VOTES_ADDR).getVotes(voter));
        console.log("Nonce EIP-712:", nonce);
        console.log("Signature (castVoteBySig):");
        console.logBytes(abi.encodePacked(r, s, v));
    }
}
