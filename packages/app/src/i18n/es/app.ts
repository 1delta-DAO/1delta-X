/** The page shell: header, language menu, receipts and errors raised in App, footer, terms page chrome. */
export const app: Record<string, string> = {
  // header
  "The beta runs on Rootstock only": "La beta funciona solo en Rootstock",
  "Your wallet is on another network. You will be asked to switch to {chain} when you sign.":
    "Tu billetera está en otra red. Se te pedirá cambiar a {chain} cuando firmes.",
  "Switch to {chain}": "Cambiar a {chain}",
  Disconnect: "Desconectar",
  "Connecting…": "Conectando…",
  "Connect wallet": "Conectar billetera",
  "No EIP-6963 wallet detected in this browser.": "No se detectó ninguna billetera EIP-6963 en este navegador.",
  "Latest block the depth feed has seen": "Último bloque que ha visto el feed de profundidad",
  syncing: "sincronizando",
  Pages: "Páginas",
  Trade: "Operar",
  Dashboard: "Panel",
  "Switch to light theme": "Cambiar a tema claro",
  "Switch to dark theme": "Cambiar a tema oscuro",
  Language: "Idioma",

  // the ladder's quote marker
  "Your quote": "Tu cotización",
  "Book estimate": "Estimación del libro",
  "via {source}": "vía {source}",
  "no filler quote": "sin cotización del filler",

  // signing and receipts
  "wallet not connected": "billetera no conectada",
  " · domain not deployed": " · dominio no desplegado",
  "{amount} {token} in {slices} slices, {every} min apart": "{amount} {token} en {slices} tramos, cada {every} min",
  "slice 1 signed at {price} {pair}; sign each later slice from Open orders when it comes due":
    "tramo 1 firmado a {price} {pair}; firma cada tramo siguiente desde Órdenes abiertas cuando le toque",
  "slice 1 of {slices} signed · posted to the orderbook": "tramo 1 de {slices} firmado · publicado en el libro de órdenes",
  "slice 1 of {slices} signed · simulated book": "tramo 1 de {slices} firmado · libro simulado",
  "{pay} → ≈ {target} {token} (at least {min})": "{pay} → ≈ {target} {token} (al menos {min})",
  "{pay} → at least {min} {token}": "{pay} → al menos {min} {token}",
  "{what} at {price}": "{what} a {price}",
  "signed at the filler's quote · posted to the orderbook. It fills at the quote within a block or two, down to your minimum if the price moves; not filled after ~2 blocks? cancel and re-quote":
    "firmada a la cotización del filler · publicada en el libro de órdenes. Se ejecuta a la cotización en uno o dos bloques, hasta tu mínimo si el precio se mueve; ¿sin ejecutar tras ~2 bloques? cancela y vuelve a cotizar",
  "signed · posted to the orderbook at your limit; fills whenever the market, net of the filler's network fee, reaches it (lives {expiry})":
    "firmada · publicada en el libro de órdenes a tu límite; se ejecuta cuando el mercado, neto de la comisión de red del filler, lo alcance (vigencia: {expiry})",
  "signed · posted to the orderbook · awaiting a filler; fills appear when they settle on-chain":
    "firmada · publicada en el libro de órdenes · esperando un filler; las ejecuciones aparecen cuando se liquidan on-chain",
  "signed · resting in the simulated book": "firmada · en el libro simulado",
  "signed · settlement simulated, nothing was broadcast": "firmada · liquidación simulada, no se transmitió nada",

  // cancels and unwrap
  "Connect a wallet on {chain} to sign a cancel": "Conecta una billetera en {chain} para firmar una cancelación",
  "Unwrap {amount} {wrapped} to {native}?\n\nOne transaction (WRBTC.withdraw). Orders that sell {wrapped} cannot fill without it.":
    "¿Desenvolver {amount} {wrapped} a {native}?\n\nUna transacción (WRBTC.withdraw). Las órdenes que venden {wrapped} no pueden ejecutarse sin él.",
  "Unwrap {amount} {wrapped}": "Desenvolver {amount} {wrapped}",
  "On-chain cancel needs a deployed Settlement and a wallet on its chain":
    "La cancelación on-chain requiere un Settlement desplegado y una billetera en su red",
  "Cancel on-chain {id}…": "Cancelar on-chain {id}…",

  // footer
  "1delta X · reference interface for UniversalSettlement": "1delta X · interfaz de referencia para UniversalSettlement",
  "Pool rungs are built from live Uniswap v3 tick liquidity via the <oku>Oku API</oku>; token metadata and icons come from <lists>1delta-DAO/token-lists</lists>.":
    "Los niveles de los pools se construyen con la liquidez por tick de Uniswap v3 en vivo, a través de la <oku>API de Oku</oku>; los metadatos e íconos de los tokens provienen de <lists>1delta-DAO/token-lists</lists>.",
  "Signed orders and soft cancels are posted to a live orderbook server; any filler can fill them on-chain, and a fill is shown only once the server reports it from the chain.":
    "Las órdenes firmadas y las cancelaciones off-chain se publican en un servidor de libro de órdenes en vivo; cualquier filler puede ejecutarlas on-chain, y una ejecución se muestra solo cuando el servidor la informa desde la cadena.",
  "Order distribution runs against an in-browser mock of the orderbook backend: signatures are real, but resting, fills and soft cancels are simulated locally, nothing is broadcast, and no fill shown here happened on-chain.":
    "La distribución de órdenes funciona contra una simulación en el navegador del backend del libro de órdenes: las firmas son reales, pero las órdenes en el libro, las ejecuciones y las cancelaciones off-chain se simulan localmente, no se transmite nada y ninguna ejecución mostrada aquí ocurrió on-chain.",
  "Prize draw Terms & Conditions": "Términos y Condiciones del sorteo",

  // terms page
  "← Back to trading": "← Volver a operar",
  "These terms exist in English only. The English text below is the one that applies.":
    "Estos términos existen solo en inglés. El texto en inglés a continuación es el que se aplica.",
  "Questions about the draw go to <mail>team@1delta.io</mail>.": "Las preguntas sobre el sorteo van a <mail>team@1delta.io</mail>.",
};
