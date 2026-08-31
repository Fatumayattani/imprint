export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "balance", type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "allowance", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "success", type: "bool" }],
  },
] as const;

const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

export const protectedRouterAbi = [
  {
    type: "function",
    name: "nonces",
    stateMutability: "view",
    inputs: [{ name: "trader", type: "address" }],
    outputs: [{ name: "nextNonce", type: "uint256" }],
  },
  {
    type: "function",
    name: "protectedSwapExactInput",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {
            name: "key",
            type: "tuple",
            components: poolKeyComponents,
          },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
          { name: "bondAmount", type: "uint256" },
          { name: "deadlineBlock", type: "uint256" },
        ],
      },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

export const imprintHookAbi = [
  {
    type: "function",
    name: "receiptId",
    stateMutability: "pure",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "trader", type: "address" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "id", type: "bytes32" }],
  },
  {
    type: "function",
    name: "receipts",
    stateMutability: "view",
    inputs: [{ name: "receiptId", type: "bytes32" }],
    outputs: [
      { name: "trader", type: "address" },
      { name: "bondToken", type: "address" },
      { name: "poolId", type: "bytes32" },
      { name: "referenceTick", type: "int24" },
      { name: "impactTick", type: "int24" },
      { name: "settleBlock", type: "uint64" },
      { name: "expiryBlock", type: "uint64" },
      { name: "declaredBond", type: "uint256" },
      { name: "requiredBond", type: "uint256" },
      { name: "status", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "settleReceipt",
    stateMutability: "nonpayable",
    inputs: [
      { name: "receiptId", type: "bytes32" },
      {
        name: "key",
        type: "tuple",
        components: poolKeyComponents,
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "expireReceipt",
    stateMutability: "nonpayable",
    inputs: [
      { name: "receiptId", type: "bytes32" },
      {
        name: "key",
        type: "tuple",
        components: poolKeyComponents,
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "donationStreams",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "bondToken", type: "address" },
    ],
    outputs: [
      { name: "reserve", type: "uint256" },
      { name: "lastDonationBlock", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "IMPACT_THRESHOLD_TICKS",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint24" }],
  },
  {
    type: "function",
    name: "MAX_BOND_BPS",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "OBSERVATION_BLOCKS",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint64" }],
  },
] as const;

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
] as const;