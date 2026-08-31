# Imprint Live Application

The live web interface for Imprint, a Uniswap v4 hook that makes large-swap price impact measurable and accountable.

The application connects to the public Imprint pool on Unichain Sepolia and supports:

- Wallet connection through RainbowKit and WalletConnect.
- Exact-input USDC to WETH protected swaps.
- Limited USDC authorization.
- Live pool pressure and LP reserve reads.
- Onchain bond receipt recovery after refresh.
- Permissionless receipt settlement and expiry.

## Local development

Install dependencies:

    npm install

Create the local environment file:

    cp .env.example .env.local

Add the public Reown project identifier:

    VITE_REOWN_PROJECT_ID=

Start the application:

    npm run dev

## Checks

    npm run lint
    npm run build

Contract addresses and pool details are maintained in `src/config.ts` and the repository deployment record.
