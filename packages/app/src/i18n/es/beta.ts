export const beta: Record<string, string> = {
  // PreAudit
  "Pre-audit beta": "Beta preauditoría",
  "These contracts are <b>unaudited</b>. Orders are capped at <b>$1,000</b> per order and per wallet during the beta, and approvals are capped at the size of each order. Trade only what you can afford to lose.":
    "Estos contratos <b>no están auditados</b>. Las órdenes están limitadas a <b>$1,000</b> por orden y por billetera durante la beta, y las aprobaciones están limitadas al tamaño de cada orden. Opera solo con lo que puedas permitirte perder.",
  "What this means": "Qué significa esto",
  "Risk disclosure": "Divulgación de riesgos",
  "Before you trade": "Antes de operar",
  "Close": "Cerrar",
  "This is an <hl>unaudited</hl> pre-audit beta.": "Esta es una beta preauditoría <hl>sin auditar</hl>.",
  "The settlement contracts have <b>not been audited</b>. They may contain bugs that cause you to lose the funds you trade or approve.":
    "Los contratos de liquidación <b>no han sido auditados</b>. Pueden contener errores que te hagan perder los fondos con los que operas o que apruebas.",
  "Token approvals are capped at the exact amount of the order you are signing. They are <b>not removed automatically</b>: an approval stays until a fill uses it or you revoke it (the app offers a one-click revoke), including after a cancel, an expiry or a partial fill. This bounds the risk; it does not remove it.":
    "Las aprobaciones de tokens están limitadas al monto exacto de la orden que estás firmando. <b>No se eliminan automáticamente</b>: una aprobación permanece hasta que una ejecución la usa o hasta que la revocas (la app ofrece revocar con un clic), incluso después de una cancelación, un vencimiento o una ejecución parcial. Esto acota el riesgo; no lo elimina.",
  "Orders are signed messages. A filler can settle any order you have signed that has not expired or been cancelled <b>on-chain</b>. Hiding an order from the book (a free, off-chain cancel) does not stop someone who already holds it.":
    "Las órdenes son mensajes firmados. Un filler puede liquidar cualquier orden que hayas firmado y que no haya vencido ni haya sido cancelada <b>on-chain</b>. Ocultar una orden del libro (una cancelación gratuita, off-chain) no detiene a quien ya la tiene.",
  "Trading can qualify your address for a <b>random prize draw</b>. Qualifying does not earn a prize and no amount of volume guarantees one. The <terms>Terms & Conditions</terms> exclude U.S. Persons and sanctioned jurisdictions, and USDRIF carries its own transfer restrictions.":
    "Operar puede hacer que tu dirección califique para un <b>sorteo aleatorio</b>. Calificar no otorga un premio y ningún volumen lo garantiza. Los <terms>Términos y Condiciones</terms> excluyen a las Personas de EE. UU. y a las jurisdicciones sancionadas, y USDRIF tiene sus propias restricciones de transferencia.",
  "Your signed orders are <b>posted to a public orderbook</b>: any filler can settle them on-chain until they expire or are cancelled on-chain. A fill is shown only once it is reported from the chain.":
    "Tus órdenes firmadas se <b>publican en un libro de órdenes público</b>: cualquier filler puede liquidarlas on-chain hasta que venzan o sean canceladas on-chain. Una ejecución se muestra solo cuando ha sido reportada desde la cadena.",
  "Order distribution and fills in this beta are <b>simulated in your browser</b>: your signatures are real, but nothing is broadcast and no fill shown here happened on-chain.":
    "La distribución de órdenes y las ejecuciones en esta beta se <b>simulan en tu navegador</b>: tus firmas son reales, pero nada se transmite y ninguna ejecución mostrada aquí ocurrió on-chain.",
  "Nothing here is financial, investment, legal or tax advice.": "Nada de lo aquí expuesto constituye asesoría financiera, de inversión, legal ni fiscal.",
  "I understand the contracts are unaudited, I accept the risk of total loss, and I agree to the Terms & Conditions.":
    "Entiendo que los contratos no están auditados, acepto el riesgo de pérdida total y acepto los Términos y Condiciones.",
  "Continue": "Continuar",

  // Raffle
  "Prize draw": "Sorteo",
  "Trading on {chain} puts your address in a <b>daily prize draw</b>, no sign-up needed. Roughly {qualifier} of trading in a day counts; a draw is held on days with more than three participating addresses, and {pool} is paid out over {cadence}. After your first swap you can also <b>rate the app</b>: a minute of feedback, optional.":
    "Operar en {chain} pone tu dirección en un <b>sorteo diario</b>, sin necesidad de registro. Cuenta operar aproximadamente {qualifier} en un día; se realiza un sorteo los días con más de tres direcciones participantes, y se reparten {pool} a lo largo de {cadence}. Después de tu primer swap también puedes <b>calificar la app</b>: un minuto de comentarios, opcional.",
  "around 100 USDRIF": "alrededor de 100 USDRIF",
  "roughly ten draws of about 10 USDRIF": "aproximadamente diez sorteos de unos 10 USDRIF",
  "Connect wallet": "Conectar billetera",
  "Trade once and you are in; the feedback form unlocks after that first swap. No funds on Rootstock? <usdt>Bridge USD₮0 on usdt0.to</usdt> (no RBTC needed) or <gas>get RBTC for gas on Gas.zip</gas>.":
    "Opera una vez y ya participas; el formulario de comentarios se desbloquea después de ese primer swap. ¿Sin fondos en Rootstock? <usdt>Trae USD₮0 por el puente de usdt0.to</usdt> (no se necesita RBTC) u <gas>obtén RBTC para gas en Gas.zip</gas>.",
  "Rate the app": "Calificar la app",
  "Thanks for the feedback.": "Gracias por tus comentarios.",
  "Update it": "Actualizarlos",
  "No funds on Rootstock? <usdt>Bridge USD₮0</usdt> · <gas>RBTC via Gas.zip</gas>": "¿Sin fondos en Rootstock? <usdt>Trae USD₮0 por puente</usdt> · <gas>RBTC vía Gas.zip</gas>",
  "{count} rated the app": "calificaciones de la app: {count}",
  "Stuck? Report a problem": "¿Atascado? Reporta un problema",
  "Winners are picked <b>at random</b> from the day’s qualifying addresses and announced by wallet address on the official channels. Trading qualifies you for a draw, it does not earn a prize, and no amount of volume guarantees one. Figures are approximate and the criteria, schedule and pool can change. Not open to U.S. Persons or persons in sanctioned jurisdictions, and USDRIF carries its own transfer restrictions. Winning addresses may be published. <terms>Full Terms</terms>":
    "Los ganadores se eligen <b>al azar</b> entre las direcciones que califican ese día y se anuncian por dirección de billetera en los canales oficiales. Operar te hace calificar para un sorteo, no otorga un premio, y ningún volumen lo garantiza. Las cifras son aproximadas y los criterios, el calendario y el monto de premios pueden cambiar. No disponible para Personas de EE. UU. ni para personas en jurisdicciones sancionadas, y USDRIF tiene sus propias restricciones de transferencia. Las direcciones ganadoras pueden ser publicadas. <terms>Términos completos</terms>",

  // Onramp
  "Bring USD₮0 on usdt0.to": "Trae USD₮0 en usdt0.to",
  "get RBTC for gas on Gas.zip": "obtén RBTC para gas en Gas.zip",
  "No funds on Rootstock? <usdt>Bridge USD₮0 from Arbitrum, Ethereum, Polygon and more on usdt0.to</usdt> (it trades with no RBTC needed) or <gas>get RBTC for gas on Gas.zip</gas>.":
    "¿Sin fondos en Rootstock? <usdt>Trae USD₮0 desde Arbitrum, Ethereum, Polygon y más por el puente de usdt0.to</usdt> (se opera sin necesidad de RBTC) u <gas>obtén RBTC para gas en Gas.zip</gas>.",

  // ErrorBoundary
  "Something went wrong.": "Algo salió mal.",
  "Try again": "Reintentar",

  // Participate
  "You declined the signature. Nothing was sent.": "Rechazaste la firma. No se envió nada.",
  "Feedback": "Comentarios",
  "Thank you. <hl>Noted.</hl>": "Gracias. <hl>Anotado.</hl>",
  "Your answers are on file for this wallet. You can update them from the notice at any time. The draw itself needs nothing from you: every day you trade the qualifying amount is a ticket.":
    "Tus respuestas quedaron registradas para esta billetera. Puedes actualizarlas desde el aviso en cualquier momento. El sorteo en sí no requiere nada de ti: cada día en que operas el monto que califica es un boleto.",
  "Update your answers": "Actualiza tus respuestas",
  "One minute of feedback": "Un minuto de comentarios",
  "Your answers shape what we fix before the audited launch. Signing is free: it is a message, not a transaction. This is optional and changes nothing about the prize draw.":
    "Tus respuestas definen lo que corregimos antes del lanzamiento auditado. Firmar es gratis: es un mensaje, no una transacción. Esto es opcional y no cambia nada del sorteo.",
  "Stored with your address: your answers, the signature and the time. Nothing personal. Answers are never published.":
    "Se guarda junto con tu dirección: tus respuestas, la firma y la hora. Nada personal. Las respuestas nunca se publican.",
  "Switch to Rootstock": "Cambiar a Rootstock",
  "Waiting for your wallet…": "Esperando a tu billetera…",
  "Sign & update": "Firmar y actualizar",
  "Sign & send feedback": "Firmar y enviar comentarios",
  "optional": "opcional",
  '"{label}" is required': '"{label}" es obligatoria',
  '"{label}": remove leading or trailing spaces': '"{label}": quita los espacios al inicio o al final',
  "the orderbook answered {status}": "el libro de órdenes respondió {status}",

  // The SDK's feedback form (lib/raffle.ts FEEDBACK_FORM_COPY)
  "Overall, how would you rate the app?": "En general, ¿cómo calificarías la app?",
  "Poor": "Mala",
  "Excellent": "Excelente",
  "How easy was placing your order?": "¿Qué tan fácil fue colocar tu orden?",
  "Very hard": "Muy difícil",
  "Very easy": "Muy fácil",
  "How safe did you feel while your order was pending?": "¿Qué tan seguro te sentiste mientras tu orden estaba pendiente?",
  "Very uneasy": "Muy intranquilo",
  "Completely safe": "Totalmente seguro",
  "Fill speed and price, compared with what you expected": "Velocidad y precio de la ejecución, comparados con lo que esperabas",
  "Much worse": "Mucho peor",
  "Much better": "Mucho mejor",
  "What did you trade for?": "¿Para qué operaste?",
  "Exit USDRIF": "Salir de USDRIF",
  "Get RBTC": "Obtener RBTC",
  "Buy or sell RIF": "Comprar o vender RIF",
  "Try the app": "Probar la app",
  "Other": "Otro",
  "What confused you or nearly stopped you?": "¿Qué te confundió o casi te hizo desistir?",
  "Which order types would you use next?": "¿Qué tipos de orden usarías después?",
  "Limit orders": "Órdenes límite",
  "Scheduled / TWAP": "Programadas / TWAP",
  "Take-profit / stop-loss": "Take-profit / stop-loss",
  "Orders on lending positions": "Órdenes sobre posiciones de préstamo",
  "None of these": "Ninguna de estas",
};
