// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ConsorcioGovernor} from "../contracts/ConsorcioGovernor.sol";
import {ConsorcioObras} from "../contracts/ConsorcioObras.sol";

/**
 * @title QueuePropuestaSepolia
 * @notice Encola en ConsorcioTimelock la Propuesta #1 aprobada en Sepolia.
 */
contract QueuePropuestaSepolia is Script {
    address public constant GOVERNOR = 0x6D38403399110487B0654fD6Eb029920739973b2;
    address public constant OBRAS = 0x881bf4F2d3f92d2d955e81ecb4FF6444986cb596;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address[] memory targets = new address[](1);
        targets[0] = OBRAS;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            (
                "Reparacion de Luminarias y Acceso Principal",
                "Recambio de reflectores LED perimetrales y barrera automatica (Hitos 30/40/30)",
                payable(deployer),
                0.0005 ether
            )
        );
        bytes32 descriptionHash = keccak256(
            bytes("Propuesta #1 ConsorcioDAO: Aprobar Obra Luminarias LED y Liberar Hito 1 (30%)")
        );

        vm.startBroadcast(deployerPrivateKey);
        ConsorcioGovernor(payable(GOVERNOR)).queue(targets, values, calldatas, descriptionHash);
        console.log("Propuesta #1 encolada en ConsorcioTimelock!");
        vm.stopBroadcast();
    }
}

/**
 * @title ExecuteYReindirHito1Sepolia
 * @notice Ejecuta la Propuesta #1 tras el minDelay (liberando el 30% del Hito 1)
 *         y presenta la rendicion de cuentas IPFS del Hito 1 en ConsorcioObras.
 */
contract ExecuteYReindirHito1Sepolia is Script {
    address public constant GOVERNOR = 0x6D38403399110487B0654fD6Eb029920739973b2;
    address public constant OBRAS = 0x881bf4F2d3f92d2d955e81ecb4FF6444986cb596;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address[] memory targets = new address[](1);
        targets[0] = OBRAS;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            ConsorcioObras.aprobarObraYLiberarHito1,
            (
                "Reparacion de Luminarias y Acceso Principal",
                "Recambio de reflectores LED perimetrales y barrera automatica (Hitos 30/40/30)",
                payable(deployer),
                0.0005 ether
            )
        );
        bytes32 descriptionHash = keccak256(
            bytes("Propuesta #1 ConsorcioDAO: Aprobar Obra Luminarias LED y Liberar Hito 1 (30%)")
        );

        vm.startBroadcast(deployerPrivateKey);
        ConsorcioGovernor(payable(GOVERNOR)).execute(targets, values, calldatas, descriptionHash);
        console.log("Propuesta #1 ejecutada! Hito 1 (30%) liberado al contratista.");

        ConsorcioObras(payable(OBRAS)).rendirCuentasHito1(
            1,
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG/facturas-luminarias-hito1.pdf"
        );
        console.log("Rendicion de cuentas del Hito 1 registrada en IPFS on-chain!");
        vm.stopBroadcast();
    }
}
