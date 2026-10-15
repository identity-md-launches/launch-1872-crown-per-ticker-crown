import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { loadDeployment, createRuntime } from "./config";
import App from "./App";
import { TransactionProvider } from "./TransactionFeed";
import "./styles.css";
const root = createRoot(document.getElementById("root")!);
root.render(
  <main className="loading-page">
    <h1>CROWN</h1>
    <p role="status">Loading the ticker registry…</p>
  </main>,
);
loadDeployment()
  .then(({ deployment, abis }) => {
    const runtime = createRuntime(deployment, abis);
    const query = new QueryClient({
      defaultOptions: { queries: { refetchOnWindowFocus: true, retry: 1 } },
    });
    root.render(
      <StrictMode>
        <WagmiProvider config={runtime.wagmi}>
          <QueryClientProvider client={query}>
            <TransactionProvider>
              <App r={runtime} />
            </TransactionProvider>
          </QueryClientProvider>
        </WagmiProvider>
      </StrictMode>,
    );
  })
  .catch((error) => {
    root.render(
      <main className="loading-page">
        <h1>CROWN</h1>
        <h2>Unable to load this launch</h2>
        <p role="alert">{error.message}</p>
        <button className="button primary" onClick={() => location.reload()}>
          Retry loading
        </button>
      </main>,
    );
  });
