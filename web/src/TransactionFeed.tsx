import { createContext, useContext, useState, type ReactNode } from "react";
import type { Hash } from "viem";
import type { Runtime } from "./config";
type Update = {
  label: string;
  hash?: Hash;
  status: "pending" | "success" | "error";
  message?: string;
};
const Feed = createContext<{
  value?: Update;
  update: (v: Update | undefined) => void;
}>({ update: () => {} });
export function TransactionProvider({ children }: { children: ReactNode }) {
  const [value, update] = useState<Update>();
  return <Feed.Provider value={{ value, update }}>{children}</Feed.Provider>;
}
export const useTransactionFeed = () => useContext(Feed);
export function TransactionStatus({ r }: { r: Runtime }) {
  const { value, update } = useTransactionFeed();
  return (
    <div className="transaction-tracker" role="status" aria-live="polite">
      {value && (
        <div className="tracker-content">
          <div>
            <strong>
              {value.status === "success"
                ? `${value.label} confirmed.`
                : value.status === "pending"
                  ? `${value.label} submitted.`
                  : `${value.label} needs attention.`}
            </strong>
            <p className="small">
              {value.status === "success"
                ? `Included on ${r.chain.name}.`
                : value.message || "Waiting for network confirmation."}
            </p>
            {value.hash && (
              <a
                href={`${r.explorer}/tx/${value.hash}`}
                target="_blank"
                rel="noreferrer"
                className="small"
              >
                View transaction ↗
              </a>
            )}
          </div>
          {value.status !== "pending" && (
            <button className="text-button" onClick={() => update(undefined)}>
              Dismiss
            </button>
          )}
        </div>
      )}
    </div>
  );
}
