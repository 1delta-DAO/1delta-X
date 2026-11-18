import { app } from "./es/app";
import { beta } from "./es/beta";
import { dashboard } from "./es/dashboard";
import { orders } from "./es/orders";
import { ticket } from "./es/ticket";

/**
 * Spanish, keyed by the English sentence (see ./index.ts). One fragment per area
 * of the app; a sentence used in two areas may sit in either, but must read the
 * same in both (test/i18n.test.ts).
 */
export const ES_FRAGMENTS: Record<string, Record<string, string>> = { app, ticket, orders, beta, dashboard };

export const ES: Record<string, string> = Object.assign({}, ...Object.values(ES_FRAGMENTS));
