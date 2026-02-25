# SmartAccountWrapper

ERC-7540 compatible async vault wrapper for smart accounts.

## Deployments

### Base Mainnet

| Contract | Address | Basescan |
|----------|---------|----------|
| Implementation | `0xEC046FeDDc0384bAB37B5e044657312015088B7A` | [View](https://basescan.org/address/0xEC046FeDDc0384bAB37B5e044657312015088B7A#code) |
| Beacon | `0x57bf1d0513490383d6832522720236903d464abf` | [View](https://basescan.org/address/0x57bf1d0513490383d6832522720236903d464abf#code) |
| Wrapper (Proxy) | `0x29d6fbe61ea5b41697a285e8ef5de6f2f9e6bd94` | [View](https://basescan.org/address/0x29d6fbe61ea5b41697a285e8ef5de6f2f9e6bd94#code) |

**Wrapper Details:**
- Name: `MySmartAccountWrapper`
- Symbol: `MSAW`
- Underlying Asset: USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`)

---

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
