import type { HttpSourceOptions } from "./http";
import type { RouteSource } from "../solver";
import { nordsternSource } from "./nordstern";
import { sushiSource } from "./sushi";

export * from "./http";
export * from "./sushi";
export * from "./nordstern";

/**
 * The DEFAULT quoter: best of Sushi and Nordstern.
 *
 * This is the floor every other solver has to beat. `QuoteSolver` queries both
 * in parallel and bids off the better number, so a competitor only wins a round
 * by actually routing better than the best public aggregator — not by being the
 * only participant. A dead source is skipped, so the default degrades to
 * whichever one is up rather than to nothing.
 */
export function defaultRouteSources(opts: HttpSourceOptions = {}): RouteSource[] {
  return [sushiSource(opts), nordsternSource(opts)];
}
