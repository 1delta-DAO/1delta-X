import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "@app/styles.css";
import "./admin.css";
import { AdminApp } from "./AdminApp";

const root = document.getElementById("root");
if (!root) throw new Error("missing #root");

createRoot(root).render(
  <StrictMode>
    <AdminApp />
  </StrictMode>,
);
