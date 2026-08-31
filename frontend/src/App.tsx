import { useMemo, useState } from "react";
import { motion } from "motion/react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  Activity,
  ArrowDown,
  CircleDot,
  Clock3,
  Droplets,
  ExternalLink,
  Orbit,
  ScanLine,
  Wallet,
} from "lucide-react";
import {
  useAccount,
  useBlockNumber,
  usePublicClient,
  useReadContract,
  useReadContracts,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import {
  formatUnits,
  parseUnits,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from "viem";

import {
  erc20Abi,
  imprintHookAbi,
  protectedRouterAbi,
  stateViewAbi,
} from "./abi";
import {
  contracts,
  deployment,
  imprintPoolKey,
  unichainSepolia,
} from "./config";
import "./App.css";

const MAX_BOND_BPS = 2_000n;
const BPS = 10_000n;
const MIN_SQRT_PRICE_LIMIT_X96 = 4_295_128_740n;

const receiptStatus = ["None", "Pending", "Settled", "Expired"];

function shorten(value?: string) {
  if (!value) return "";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function formatUsdc(value?: bigint) {
  return Number(formatUnits(value ?? 0n, 6)).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 6,
  });
}

function formatWeth(value?: bigint) {
  return Number(formatUnits(value ?? 0n, 18)).toLocaleString(undefined, {
    minimumFractionDigits: 4,
    maximumFractionDigits: 8,
  });
}


function WalletConnectControl({
  primary = false,
}: {
  primary?: boolean;
}) {
  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        mounted,
        openAccountModal,
        openChainModal,
        openConnectModal,
      }) => {
        const connected = mounted && account && chain;
        const className = primary
          ? "primary-action"
          : `wallet-button${connected ? " connected" : ""}`;

        if (!connected) {
          return (
            <button className={className} onClick={openConnectModal} type="button">
              <Wallet size={17} />
              Connect wallet
            </button>
          );
        }

        if (chain.unsupported) {
          return (
            <button className={className} onClick={openChainModal} type="button">
              Switch network
            </button>
          );
        }

        return (
          <button className={className} onClick={openAccountModal} type="button">
            <Wallet size={17} />
            {account.displayName}
          </button>
        );
      }}
    </ConnectButton.Custom>
  );
}

export default function App() {
  const { address, chainId, isConnected } = useAccount();
  const { switchChain } = useSwitchChain();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const { data: currentBlock } = useBlockNumber({ watch: true });

  const [amount, setAmount] = useState("0.1");
  const [busyAction, setBusyAction] = useState<"approve" | "swap" | "settle" | "expire" | null>(
    null,
  );
  const [notice, setNotice] = useState<string | null>(null);
  const [lastHash, setLastHash] = useState<Hex>();
  const [lastReceiptId, setLastReceiptId] = useState<Hex>();

  const amountIn = useMemo(() => {
    try {
      return parseUnits(amount || "0", 6);
    } catch {
      return 0n;
    }
  }, [amount]);

  const declaredBond = (amountIn * MAX_BOND_BPS) / BPS;
  const totalAuthorization = amountIn + declaredBond;

  const { data: accountReads, refetch: refetchAccount } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: contracts.usdc,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [address ?? contracts.protectedRouter],
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.weth,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [address ?? contracts.protectedRouter],
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.usdc,
        abi: erc20Abi,
        functionName: "allowance",
        args: [
          address ?? contracts.protectedRouter,
          contracts.protectedRouter,
        ],
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.protectedRouter,
        abi: protectedRouterAbi,
        functionName: "nonces",
        args: [address ?? contracts.protectedRouter],
        chainId: unichainSepolia.id,
      },
    ],
    query: {
      enabled: Boolean(address),
      refetchInterval: 5_000,
    },
  });

  const { data: protocolReads } = useReadContracts({
    allowFailure: false,
    contracts: [
      {
        address: contracts.stateView,
        abi: stateViewAbi,
        functionName: "getSlot0",
        args: [deployment.poolId],
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.hook,
        abi: imprintHookAbi,
        functionName: "donationStreams",
        args: [deployment.poolId, contracts.usdc],
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.hook,
        abi: imprintHookAbi,
        functionName: "IMPACT_THRESHOLD_TICKS",
        chainId: unichainSepolia.id,
      },
      {
        address: contracts.hook,
        abi: imprintHookAbi,
        functionName: "OBSERVATION_BLOCKS",
        chainId: unichainSepolia.id,
      },
    ],
    query: {
      refetchInterval: 5_000,
    },
  });

  const usdcBalance = accountReads?.[0]?.result as bigint | undefined;
  const wethBalance = accountReads?.[1]?.result as bigint | undefined;
  const allowance = accountReads?.[2]?.result as bigint | undefined;
  const nextNonce = (accountReads?.[3]?.result as bigint | undefined) ?? 0n;

  const latestReceiptNonce = nextNonce > 0n ? nextNonce - 1n : 0n;

  const { data: recoveredReceiptId } = useReadContract({
    address: contracts.hook,
    abi: imprintHookAbi,
    functionName: "receiptId",
    args: [
      deployment.poolId,
      address ?? zeroAddress,
      latestReceiptNonce,
    ],
    chainId: unichainSepolia.id,
    query: {
      enabled: Boolean(address) && nextNonce > 0n,
    },
  });

  const activeReceiptId = lastReceiptId ?? recoveredReceiptId;

  const { data: receipt, refetch: refetchReceipt } = useReadContract({
    address: contracts.hook,
    abi: imprintHookAbi,
    functionName: "receipts",
    args: [activeReceiptId ?? zeroHash],
    chainId: unichainSepolia.id,
    query: {
      enabled: Boolean(activeReceiptId),
      refetchInterval: 4_000,
    },
  });

  const slot0 = protocolReads?.[0] as
    | readonly [bigint, number, number, number]
    | undefined;
  const donationStream = protocolReads?.[1] as
    | readonly [bigint, bigint]
    | undefined;
  const impactThreshold = protocolReads?.[2] as number | undefined;
  const observationBlocks = protocolReads?.[3] as bigint | undefined;

  const currentTick = slot0?.[1] ?? deployment.initialTick;
  const lpFee = slot0?.[3] ?? 3_000;
  const donationReserve = donationStream?.[0] ?? 0n;
  const insufficientBalance =
    isConnected &&
    usdcBalance !== undefined &&
    usdcBalance < totalAuthorization;

  const needsApproval =
    isConnected &&
    !insufficientBalance &&
    (allowance ?? 0n) < totalAuthorization;

  const displayedNotice = !isConnected
    ? "Connect a wallet to leave your first protected imprint."
    : chainId !== unichainSepolia.id
      ? "Switch to Unichain Sepolia to use the live Imprint pool."
      : notice ??
        "Wallet connected. Enter an amount to prepare a protected swap.";

  const liveReceipt = receipt as
    | readonly [
        Address,
        Address,
        Hex,
        number,
        number,
        bigint,
        bigint,
        bigint,
        bigint,
        number,
      ]
    | undefined;

  const receiptImpact = liveReceipt
    ? Math.abs(liveReceipt[3] - liveReceipt[4])
    : 0;

  const resolutionAction =
    liveReceipt &&
    liveReceipt[9] === 1 &&
    currentBlock !== undefined
      ? currentBlock < liveReceipt[5]
        ? "waiting"
        : currentBlock <= liveReceipt[6]
          ? "settle"
          : "expire"
      : null;

  async function resolveReceipt(action: "settle" | "expire") {
    if (!activeReceiptId || !(await ensureNetwork())) return;

    try {
      setBusyAction(action);
      setNotice(
        action === "settle"
          ? "Confirm receipt settlement in your wallet."
          : "Confirm receipt expiry in your wallet.",
      );

      const hash = await writeContractAsync({
        address: contracts.hook,
        abi: imprintHookAbi,
        functionName:
          action === "settle" ? "settleReceipt" : "expireReceipt",
        args: [activeReceiptId, imprintPoolKey],
        chainId: unichainSepolia.id,
      });

      setLastHash(hash);
      setNotice("Receipt resolution submitted. Waiting for confirmation…");
      await publicClient?.waitForTransactionReceipt({ hash });
      await refetchReceipt();
      await refetchAccount();
      setNotice(
        action === "settle"
          ? "Receipt settled. The bond outcome is finalized."
          : "Receipt expired. Excess bond was refunded and LP compensation queued.",
      );
    } catch (error) {
      setNotice(
        error instanceof Error
          ? "shortMessage" in error && typeof error.shortMessage === "string"
            ? error.shortMessage
            : error.message
          : "Receipt resolution cancelled.",
      );
    } finally {
      setBusyAction(null);
    }
  }

  async function ensureNetwork() {
    if (chainId !== unichainSepolia.id) {
      switchChain({ chainId: unichainSepolia.id });
      return false;
    }
    return true;
  }

  async function approveRouter() {
    if (!address || totalAuthorization === 0n) return;
    if (!(await ensureNetwork())) return;

    try {
      setBusyAction("approve");
      setNotice("Confirm the USDC authorization in your wallet.");

      const hash = await writeContractAsync({
        address: contracts.usdc,
        abi: erc20Abi,
        functionName: "approve",
        args: [contracts.protectedRouter, totalAuthorization],
        chainId: unichainSepolia.id,
      });

      setLastHash(hash);
      setNotice("Authorization submitted. Waiting for confirmation…");
      await publicClient?.waitForTransactionReceipt({ hash });
      await refetchAccount();
      setNotice("USDC authorized. Your protected swap is ready.");
    } catch (error) {
      setNotice(
        error instanceof Error
            ? "shortMessage" in error && typeof error.shortMessage === "string"
              ? error.shortMessage
              : error.message
            : "Authorization cancelled.",
      );
    } finally {
      setBusyAction(null);
    }
  }

  async function executeProtectedSwap() {
    if (!address || amountIn === 0n || !currentBlock) return;
    if (!(await ensureNetwork())) return;

    try {
      setBusyAction("swap");
      setNotice("Confirm your protected swap in the wallet.");

      const nonce = nextNonce;
      const hash = await writeContractAsync({
        address: contracts.protectedRouter,
        abi: protectedRouterAbi,
        functionName: "protectedSwapExactInput",
        args: [
          {
            key: imprintPoolKey,
            zeroForOne: true,
            amountIn,
            amountOutMinimum: 1n,
            sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT_X96,
            bondAmount: declaredBond,
            deadlineBlock: currentBlock + 100n,
          },
        ],
        chainId: unichainSepolia.id,
      });

      setLastHash(hash);
      setNotice("Swap submitted. Imprint is measuring the price trace…");
      await publicClient?.waitForTransactionReceipt({ hash });

      const id = await publicClient?.readContract({
        address: contracts.hook,
        abi: imprintHookAbi,
        functionName: "receiptId",
        args: [deployment.poolId, address, nonce],
      });

      if (id) setLastReceiptId(id);
      await refetchAccount();
      setNotice("Protected swap confirmed. Your bond receipt is live.");
    } catch (error) {
      setNotice(
        error instanceof Error
            ? "shortMessage" in error && typeof error.shortMessage === "string"
              ? error.shortMessage
              : error.message
            : "Swap cancelled.",
      );
    } finally {
      setBusyAction(null);
    }
  }

  return (
    <main className="app-shell">
      <div className="pressure-field pressure-field-one" />
      <div className="pressure-field pressure-field-two" />

      <nav className="topbar">
        <a className="brand" href="#" aria-label="Imprint home">
          <span className="brand-mark">
            <span />
            <span />
            <span />
          </span>
          <span>IMPRINT</span>
        </a>

        <WalletConnectControl />
      </nav>

      <section className="hero-grid">
        <div className="hero-copy">
          <motion.div
            className="eyebrow"
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
          >
            <ScanLine size={16} />
            Price impact, made accountable
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.08 }}
          >
            Every large swap
            <span> leaves an imprint.</span>
          </motion.h1>

          <motion.p
            className="hero-intro"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.18 }}
          >
            Imprint turns temporary price impact into a measurable bond.
            Persistent moves earn a refund. Reversed moves compensate the
            liquidity that absorbed them.
          </motion.p>

          <div className="hero-proof">
            <div><strong>51</strong><span>tests passing</span></div>
            <div><strong>166</strong><span>ticks measured live</span></div>
            <div><strong>10%</strong><span>LP release slices</span></div>
          </div>
        </div>

        <motion.section
          className="swap-card"
          initial={{ opacity: 0, y: 24, rotate: 0.5 }}
          animate={{ opacity: 1, y: 0, rotate: 0 }}
          transition={{ delay: 0.12 }}
        >
          <div className="card-heading">
            <div>
              <span className="section-label">Protected swap</span>
              <h2>USDC → WETH</h2>
            </div>
            <div className="live-chip">
              <CircleDot size={14} />
              Live pool
            </div>
          </div>

          <label className="token-input">
            <span className="input-label">You send</span>
            <div>
              <input
                value={amount}
                onChange={(event) => setAmount(event.target.value)}
                inputMode="decimal"
                aria-label="USDC amount"
              />
              <span className="token-symbol">USDC</span>
            </div>
            <small>Balance {formatUsdc(usdcBalance)} USDC</small>
          </label>

          <div className="swap-arrow">
            <ArrowDown size={18} />
          </div>

          <div className="receive-panel">
            <span className="input-label">You receive</span>
            <div>
              <strong>Calculated onchain</strong>
              <span className="token-symbol">WETH</span>
            </div>
            <small>Balance {formatWeth(wethBalance)} WETH</small>
          </div>

          <div className="bond-panel">
            <div className="bond-title">
              <span>Refundable impact bond</span>
              <strong>{formatUsdc(declaredBond)} USDC</strong>
            </div>
            <div className="bond-track">
              <span style={{ width: "20%" }} />
            </div>
            <p>
              This is the 20% safety ceiling. Imprint calculates the required
              bond from measured tick impact and returns any excess.
            </p>
          </div>

          {!isConnected ? (
            <WalletConnectControl primary />
          ) : chainId !== unichainSepolia.id ? (
            <button
              className="primary-action"
              onClick={() => switchChain({ chainId: unichainSepolia.id })}
            >
              Switch to Unichain Sepolia
            </button>
          ) : insufficientBalance ? (
            <button className="primary-action" disabled>
              Insufficient USDC balance
            </button>
          ) : needsApproval ? (
            <button
              className="primary-action"
              onClick={approveRouter}
              disabled={busyAction !== null || amountIn === 0n}
            >
              {busyAction === "approve"
                ? "Authorizing USDC…"
                : `Authorize ${formatUsdc(totalAuthorization)} USDC`}
            </button>
          ) : (
            <button
              className="primary-action inked"
              onClick={executeProtectedSwap}
              disabled={busyAction !== null || amountIn === 0n}
            >
              {busyAction === "swap"
                ? "Leaving your imprint…"
                : "Execute protected swap"}
            </button>
          )}

          {(!isConnected ||
            chainId !== unichainSepolia.id ||
            notice !== null) && (
            <div className="transaction-notice" aria-live="polite">
              <Orbit size={16} />
              <span>{displayedNotice}</span>
            </div>
          )}

          {lastHash && (
            <a
              className="transaction-link"
              href={`${unichainSepolia.blockExplorers.default.url}/tx/${lastHash}`}
              target="_blank"
              rel="noreferrer"
            >
              View latest transaction <ExternalLink size={14} />
            </a>
          )}
        </motion.section>

        <motion.aside
          className="impact-card"
          initial={{ opacity: 0, x: 22 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ delay: 0.2 }}
        >
          <div className="impact-card-header">
            <div>
              <span className="section-label">Impact trace</span>
              <h2>Pool pressure</h2>
            </div>
            <Activity size={21} />
          </div>

          <div className="trace-visual" aria-hidden="true">
            <span className="trace-ring ring-one" />
            <span className="trace-ring ring-two" />
            <span className="trace-ring ring-three" />
            <span className="trace-core">{currentTick}</span>
          </div>

          <div className="metric-grid">
            <div>
              <span>Current tick</span>
              <strong>{currentTick.toLocaleString()}</strong>
            </div>
            <div>
              <span>Impact threshold</span>
              <strong>{impactThreshold ?? 50} ticks</strong>
            </div>
            <div>
              <span>LP fee</span>
              <strong>{(lpFee / 10_000).toFixed(2)}%</strong>
            </div>
            <div>
              <span>Observation</span>
              <strong>{observationBlocks?.toString() ?? "20"} blocks</strong>
            </div>
          </div>

          <div className="reserve-strip">
            <Droplets size={18} />
            <div>
              <span>Streaming LP reserve</span>
              <strong>{formatUsdc(donationReserve)} USDC</strong>
            </div>
          </div>
        </motion.aside>
      </section>

      <section className="protocol-story">
        <div className="story-heading">
          <span className="section-label">The protection cycle</span>
          <h2>Pressure becomes proof.</h2>
        </div>

        <div className="cycle-grid">
          {[
            ["01", "Measure", "Capture the pool tick before and after the swap."],
            ["02", "Bond", "Scale the refundable bond to measured displacement."],
            ["03", "Observe", "Watch whether the price movement persists."],
            ["04", "Resolve", "Refund the trader or stream value back to LPs."],
          ].map(([number, title, copy], index) => (
            <motion.article
              key={title}
              initial={{ opacity: 0, y: 18 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: index * 0.07 }}
            >
              <span>{number}</span>
              <h3>{title}</h3>
              <p>{copy}</p>
            </motion.article>
          ))}
        </div>
      </section>

      <section className="receipt-section">
        <div className="receipt-heading">
          <div>
            <span className="section-label">Bond receipt</span>
            <h2>
              {liveReceipt
                ? `Receipt ${shorten(activeReceiptId)}`
                : "Your next imprint will appear here"}
            </h2>
          </div>
          <Clock3 size={22} />
        </div>

        {liveReceipt ? (
          <>
          <div className="receipt-grid">
            <div>
              <span>Status</span>
              <strong>{receiptStatus[liveReceipt[9]] ?? "Unknown"}</strong>
            </div>
            <div>
              <span>Measured impact</span>
              <strong>{receiptImpact} ticks</strong>
            </div>
            <div>
              <span>Declared bond</span>
              <strong>{formatUsdc(liveReceipt[7])} USDC</strong>
            </div>
            <div>
              <span>Required bond</span>
              <strong>{formatUsdc(liveReceipt[8])} USDC</strong>
            </div>
            <div>
              <span>Settlement block</span>
              <strong>{liveReceipt[5].toString()}</strong>
            </div>
            <div>
              <span>Expiry block</span>
              <strong>{liveReceipt[6].toString()}</strong>
            </div>
          </div>

          {resolutionAction === "waiting" ? (
            <button className="receipt-action" disabled>
              Settlement opens at block {liveReceipt[5].toString()}
            </button>
          ) : resolutionAction === "settle" ? (
            <button
              className="receipt-action"
              onClick={() => resolveReceipt("settle")}
              disabled={busyAction !== null}
            >
              {busyAction === "settle" ? "Settling receipt…" : "Settle receipt"}
            </button>
          ) : resolutionAction === "expire" ? (
            <button
              className="receipt-action"
              onClick={() => resolveReceipt("expire")}
              disabled={busyAction !== null}
            >
              {busyAction === "expire" ? "Expiring receipt…" : "Expire receipt"}
            </button>
          ) : null}
        </>
        ) : (
          <div className="empty-receipt">
            <span className="empty-mark" />
            <p>
              Connect your wallet and execute a protected swap. Imprint will
              generate a live onchain receipt with the measured displacement,
              required bond, and settlement window.
            </p>
          </div>
        )}
      </section>

      <footer>
        <div className="brand footer-brand">
          <span className="brand-mark">
            <span />
            <span />
            <span />
          </span>
          <span>IMPRINT</span>
        </div>
        <p>Sustainable liquidity through accountable price impact.</p>
        <a
          href={`${unichainSepolia.blockExplorers.default.url}/address/${contracts.hook}`}
          target="_blank"
          rel="noreferrer"
        >
          Verified hook <ExternalLink size={13} />
        </a>
      </footer>
    </main>
  );
}