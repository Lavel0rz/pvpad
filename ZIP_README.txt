PvPad Foundry bundle
======================

Quick start (dependencies included under lib/):
  forge test

If lib/ is missing or incomplete, from the project root run:

  forge install foundry-rs/forge-std
  forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
  forge install Uniswap/v4-core
  forge install Uniswap/v4-periphery

Pinned refs are also recorded in foundry.lock and .gitmodules.

Requirements: Foundry (forge) with solc 0.8.26 / cancun (see foundry.toml).
