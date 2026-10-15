import { useEffect, useRef, useState, type ReactNode } from "react";
import { getAddress, type Address } from "viem";
import type { Runtime } from "./config";
export function Crown({ size = 24 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 40 40"
      fill="none"
      aria-hidden="true"
    >
      <path d="m5 11 10 8 5-13 5 13 10-8-4 20H9z" fill="currentColor" />
      <path d="M10 36h20" stroke="currentColor" strokeWidth="2" />
    </svg>
  );
}
export function Arrow() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <path d="M5 12h14m-6-6 6 6-6 6" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
export function Modal({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = dialog.current;
    if (!d) return;
    const before = document.activeElement as HTMLElement;
    if (open) {
      d.showModal();
      document.body.style.overflow = "hidden";
    } else d.close();
    return () => {
      document.body.style.overflow = "";
      if (d.open) d.close();
      before?.focus();
    };
  }, [open]);
  return (
    <dialog
      ref={dialog}
      aria-label={title}
      onCancel={onClose}
      onKeyDown={(event) => {
        if (event.key !== "Tab") return;
        const controls = Array.from(
          event.currentTarget.querySelectorAll<HTMLElement>(
            'button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), summary, [tabindex="0"]',
          ),
        ).filter((element) => element.getClientRects().length > 0);
        const first = controls[0],
          last = controls.at(-1);
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }}
      onClick={(e) => {
        if (e.target === dialog.current) onClose();
      }}
    >
      <div className="dialog-inner">
        <div className="section-head">
          <h2>{title}</h2>
          <button
            className="icon-button"
            onClick={onClose}
            aria-label="Close dialog"
          >
            ×
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}
export function AddressView({
  value,
  r,
  label = "address",
  compact = false,
}: {
  value?: Address;
  r: Runtime;
  label?: string;
  compact?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (copied) {
      const id = setTimeout(() => setCopied(false), 2000);
      return () => clearTimeout(id);
    }
  }, [copied]);
  if (!value)
    return (
      <span className="muted">
        {r.ready ? "Unavailable" : "Awaiting launch"}
      </span>
    );
  const full = getAddress(value);
  return (
    <span className={`address ${compact ? "compact" : ""}`}>
      <a
        href={`${r.explorer}/address/${full}`}
        target="_blank"
        rel="noreferrer"
        aria-label={`View ${label}: ${full}`}
      >
        <code>{full}</code>
      </a>
      <button
        className="copy-button"
        aria-label={`Copy ${label}`}
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(full);
            setCopied(true);
          } catch {
            setCopied(false);
          }
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </span>
  );
}
export function Notice({
  children,
  error = false,
}: {
  children: ReactNode;
  error?: boolean;
}) {
  return (
    <p
      className={error ? "notice error" : "notice"}
      role={error ? "alert" : undefined}
    >
      {children}
    </p>
  );
}
