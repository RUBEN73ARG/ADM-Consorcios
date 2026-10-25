## Sūrya's Description Report

### Files Description Table


|  File Name  |  SHA-1 Hash  |
|-------------|--------------|
| contracts/ConsorcioGovernor.sol | b8319157ba7b03cbb320e78cbc66988100adeb7d |
| contracts/ConsorcioObras.sol | 9fc8147540f9f8454c0d9c6494a009b1666af4c3 |
| contracts/ConsorcioTimelock.sol | 5e2789e931d0f7365c36dc4c589326dcffd6ae7c |
| contracts/ConsorcioVotes.sol | b280b0394feea294060a5758038a60ea964a33f6 |


### Contracts Description Table


|  Contract  |         Type        |       Bases      |                  |                 |
|:----------:|:-------------------:|:----------------:|:----------------:|:---------------:|
|     └      |  **Function Name**  |  **Visibility**  |  **Mutability**  |  **Modifiers**  |
||||||
| **ConsorcioGovernor** | Implementation | Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorVotesQuorumFraction, GovernorTimelockControl |||
| └ | <Constructor> | Public ❗️ | 🛑  | Governor GovernorSettings GovernorVotes GovernorVotesQuorumFraction GovernorTimelockControl |
| └ | votingDelay | Public ❗️ |   |NO❗️ |
| └ | votingPeriod | Public ❗️ |   |NO❗️ |
| └ | quorum | Public ❗️ |   |NO❗️ |
| └ | state | Public ❗️ |   |NO❗️ |
| └ | proposalNeedsQueuing | Public ❗️ |   |NO❗️ |
| └ | proposalThreshold | Public ❗️ |   |NO❗️ |
| └ | _queueOperations | Internal 🔒 | 🛑  | |
| └ | _executeOperations | Internal 🔒 | 🛑  | |
| └ | _cancel | Internal 🔒 | 🛑  | |
| └ | _executor | Internal 🔒 |   | |
||||||
| **ConsorcioObras** | Implementation | ReentrancyGuard, Pausable |||
| └ | <Constructor> | Public ❗️ | 🛑  |NO❗️ |
| └ | pausarVault | External ❗️ | 🛑  | onlyTimelock |
| └ | reanudarVault | External ❗️ | 🛑  | onlyTimelock |
| └ | pagarExpensas | External ❗️ |  💵 | whenNotPaused |
| └ | <Receive Ether> | External ❗️ |  💵 |NO❗️ |
| └ | aprobarObraYLiberarHito1 | External ❗️ | 🛑  | onlyTimelock whenNotPaused nonReentrant |
| └ | crearObra | External ❗️ | 🛑  | onlyTimelock whenNotPaused |
| └ | liberarHito1 | External ❗️ | 🛑  | onlyTimelock whenNotPaused nonReentrant |
| └ | rendirCuentasHito1 | External ❗️ | 🛑  | whenNotPaused |
| └ | rendirCuentasHito2 | External ❗️ | 🛑  | whenNotPaused |
| └ | liberarHito2 | External ❗️ | 🛑  | onlyTimelock whenNotPaused nonReentrant |
| └ | liberarHito3Final | External ❗️ | 🛑  | onlyTimelock whenNotPaused nonReentrant |
| └ | cancelarObra | External ❗️ | 🛑  | onlyTimelock |
| └ | saldoLibreDisponible | Public ❗️ |   |NO❗️ |
| └ | calcularDesgloseHitos | External ❗️ |   |NO❗️ |
| └ | _validarObraExistente | Internal 🔒 |   | |
| └ | _crearObraInterna | Internal 🔒 | 🛑  | |
| └ | _liberarHito1Interno | Internal 🔒 | 🛑  | |
| └ | _transferirETH | Internal 🔒 | 🛑  | |
||||||
| **ConsorcioTimelock** | Implementation | TimelockController |||
| └ | <Constructor> | Public ❗️ | 🛑  | TimelockController |
| └ | configurarYSellarGobernanza | External ❗️ | 🛑  | onlyRole |
||||||
| **ConsorcioVotes** | Implementation | ERC721, EIP712, ERC721Votes, Ownable2Step |||
| └ | <Constructor> | Public ❗️ | 🛑  | ERC721 EIP712 Ownable |
| └ | adjudicarUnidad | External ❗️ | 🛑  | onlyOwner |
| └ | reasignarUnidad | External ❗️ | 🛑  | onlyOwner |
| └ | configurarTransferencias | External ❗️ | 🛑  | onlyOwner |
| └ | propietarioDeUnidad | External ❗️ |   |NO❗️ |
| └ | clock | Public ❗️ |   |NO❗️ |
| └ | CLOCK_MODE | Public ❗️ |   |NO❗️ |
| └ | _update | Internal 🔒 | 🛑  | |
| └ | _increaseBalance | Internal 🔒 | 🛑  | |


### Legend

|  Symbol  |  Meaning  |
|:--------:|-----------|
|    🛑    | Function can modify state |
|    💵    | Function is payable |
