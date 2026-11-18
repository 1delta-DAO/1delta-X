export const dashboard: Record<string, string> = {
  // components/Dashboard.tsx
  "Daily volume · last {n} days (UTC)": "Volumen diario · últimos {n} días (UTC)",
  "{day} · volume {volume} · turnover {turnover} · {n} fill":
    "{day} · volumen {volume} · rotación {turnover} · {n} ejecución",
  "{day} · volume {volume} · turnover {turnover} · {n} fills":
    "{day} · volumen {volume} · rotación {turnover} · {n} ejecuciones",
  "peak {max}": "máximo {max}",
  "Daily fill volume in USD": "Volumen diario de ejecuciones en USD",
  "Fills": "Ejecuciones",
  "Volume": "Volumen",
  "Turnover": "Rotación",
  "Share": "Cuota",
  "No fills yet.": "Aún no hay ejecuciones.",
  "Latest fills · all makers": "Últimas ejecuciones · todos los makers",
  "Time": "Hora",
  "Pair": "Par",
  "Size": "Tamaño",
  "Filled by": "Ejecutada por",
  "Tx": "Tx",
  "Dashboard · every fill on the 1delta X orderbook": "Panel · cada ejecución en el libro de órdenes de 1delta X",
  "loading…": "cargando…",
  "updated every minute": "se actualiza cada minuto",
  "updated every minute · oldest fills not loaded": "se actualiza cada minuto · las ejecuciones más antiguas no se cargaron",
  "netted · {n} fills": "neto · {n} ejecuciones",
  "reading {n} transaction…": "leyendo {n} transacción…",
  "reading {n} transactions…": "leyendo {n} transacciones…",
  "every conversion, incl. route hops": "cada conversión, incl. los saltos de la ruta",
  "Last 24 h": "Últimas 24 h",
  "volume · {n} fills": "volumen · {n} ejecuciones",
  "Makers": "Makers",
  "distinct wallets": "billeteras distintas",
  "Each fill is sized on the exactly-filled leg of its order (what a seller paid, what a buyer received) at today's USD price. Volume is the USD that really changed hands: opposite fills settled in the same transaction net (two matched orders count once). Turnover is every conversion that ran: each pool hop of a routed fill (a two-hop route counts about twice), and the fill itself when it needed no swap (filled from inventory).":
    "Cada ejecución se mide por el lado de su orden que se ejecuta de forma exacta (lo que pagó quien vende, lo que recibió quien compra), al precio en USD de hoy. El volumen son los USD que realmente cambiaron de manos: las ejecuciones opuestas liquidadas en la misma transacción se compensan (dos órdenes cruzadas entre sí cuentan una vez). La rotación es cada conversión que se realizó: cada salto por un pool de una ejecución enrutada (una ruta de dos saltos cuenta aproximadamente el doble) y la propia ejecución cuando no necesitó un swap (ejecutada desde inventario).",
  "{n} older fill could not be sized (the orderbook no longer holds the order).":
    "{n} ejecución antigua no se pudo medir (el libro de órdenes ya no conserva la orden).",
  "{n} older fills could not be sized (the orderbook no longer holds the order).":
    "{n} ejecuciones antiguas no se pudieron medir (el libro de órdenes ya no conserva la orden).",
  "By pair": "Por par",
  "pair": "par",
  "By filler": "Por filler",
  "filler": "filler",

  // lib/dashboard.ts
  "1delta inventory": "inventario de 1delta",
  "unknown": "desconocido",

  // hooks/useAllFills.ts
  "the orderbook is rate-limiting us; retrying shortly": "el libro de órdenes nos está limitando las solicitudes; reintentamos en breve",
  "orderbook answered {status}": "el libro de órdenes respondió {status}",
  "no orderbook server in this build": "esta versión no tiene servidor de libro de órdenes",

  // wallet
  "wallet not available": "billetera no disponible",
  "Transaction": "Transacción",
  "Reset the approval to 0": "Restablecer la aprobación a 0",
  "{symbol} wrapped, but the balance is still short. Try again": "{symbol} envuelto, pero el saldo sigue siendo insuficiente. Inténtalo de nuevo",

  // lib/chain.ts, config
  "deployment mismatch: Settlement uses Permit3 {wired}, config names {permit3}":
    "el despliegue no coincide: Settlement usa Permit3 {wired}, la configuración indica {permit3}",
  "Chain {id}": "Red {id}",
  "via {hubs} · {pools}": "vía {hubs} · {pools}",

  // backend/remote.ts
  "no reason given": "sin motivo indicado",
  "The orderbook is temporarily unavailable ({reason}). The order was NOT posted. Try again.":
    "El libro de órdenes no está disponible temporalmente ({reason}). La orden NO se publicó. Inténtalo de nuevo.",
  "The orderbook is temporarily unavailable ({reason}). The cancel was NOT posted. Try again.":
    "El libro de órdenes no está disponible temporalmente ({reason}). La cancelación NO se publicó. Inténtalo de nuevo.",
  "The orderbook is rate-limiting this address ({reason}). The order was NOT posted. Wait and try again.":
    "El libro de órdenes está limitando las solicitudes de esta dirección ({reason}). La orden NO se publicó. Espera e inténtalo de nuevo.",
  "The orderbook is rate-limiting this address ({reason}). The cancel was NOT posted. Wait and try again.":
    "El libro de órdenes está limitando las solicitudes de esta dirección ({reason}). La cancelación NO se publicó. Espera e inténtalo de nuevo.",
  "The orderbook rejected the order: {reason}": "El libro de órdenes rechazó la orden: {reason}",
  "The orderbook rejected the cancel: {reason}": "El libro de órdenes rechazó la cancelación: {reason}",
  "The orderbook refused the order: {reason}": "El libro de órdenes no aceptó la orden: {reason}",
  "The orderbook refused the cancel: {reason}": "El libro de órdenes no aceptó la cancelación: {reason}",
  "The orderbook answered {status} ({reason}). The order was NOT posted.":
    "El libro de órdenes respondió {status} ({reason}). La orden NO se publicó.",
  "The orderbook answered {status} ({reason}). The cancel was NOT posted.":
    "El libro de órdenes respondió {status} ({reason}). La cancelación NO se publicó.",
  "Could not reach the orderbook at {url}: {error}": "No se pudo conectar con el libro de órdenes en {url}: {error}",
  "The orderbook acknowledged a different order hash ({hash}); not tracking it":
    "El libro de órdenes confirmó un hash de orden distinto ({hash}); no se le dará seguimiento",
  "No Settlement is deployed on this chain. The order was signed but cannot be posted to the orderbook":
    "No hay un Settlement desplegado en esta red. La orden se firmó, pero no se puede publicar en el libro de órdenes",
  "No Settlement is deployed on this chain, so the slice cannot be posted":
    "No hay un Settlement desplegado en esta red, así que el tramo no se puede publicar",
  "the orderbook no longer knows this order (server restarted?). It is still fillable on-chain until expiry":
    "el libro de órdenes ya no conoce esta orden (¿se reinició el servidor?). Aún se puede ejecutar on-chain hasta su vencimiento",
  "no longer distributed by the orderbook (expired, unfunded or invalidated). Cancel on-chain to be sure it cannot fill":
    "el libro de órdenes ya no la distribuye (vencida, sin fondos o invalidada). Cancélala on-chain para asegurarte de que no se pueda ejecutar",
};
