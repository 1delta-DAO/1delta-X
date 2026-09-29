import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { TermsPage } from "./components/Terms";
import "./styles.css";

// A second Vite entry rather than a route: the terms are a static document with
// no wallet, no feed and no order state, so a router would only buy the ability
// to ship the trading bundle to someone who came to read a legal page.
const root = document.getElementById("root");
if (!root) throw new Error("missing #root");

createRoot(root).render(
  <StrictMode>
    <TermsPage />
  </StrictMode>,
);
