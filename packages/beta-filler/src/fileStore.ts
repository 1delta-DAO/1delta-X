// Node-only helpers for the CLI (bin.ts). Nothing in the platform-agnostic core
// (./core.ts and everything it imports) may import this file.
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

import { entryFromJson, type BookEntry } from "./intake";
import { STATE_KEY, type StateStore } from "./state";

/**
 * A {@link StateStore} on the local disk. The engine's state (key `state`) IS the
 * file at `path` — the same JSON a pre-2026-10 STATE_FILE held — and any other key
 * lives next to it at `<path>.<key>`. Writes go to a temp file and are renamed
 * into place, so a crash mid-write cannot leave half a JSON document.
 */
export class FileStateStore implements StateStore {
  constructor(private readonly path: string) {}

  private file(key: string): string {
    return key === STATE_KEY ? this.path : `${this.path}.${key}`;
  }

  async get<T>(key: string): Promise<T | undefined> {
    const f = this.file(key);
    return existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as T) : undefined;
  }

  async put(key: string, value: unknown): Promise<void> {
    const f = this.file(key);
    const tmp = `${f}.tmp`;
    writeFileSync(tmp, JSON.stringify(value, null, 1));
    renameSync(tmp, f);
  }
}

/** One order from a local JSON file — `{order, sig, fillAmount?}` (see `entryFromJson`). */
export function entryFromFile(path: string): BookEntry {
  return entryFromJson(JSON.parse(readFileSync(path, "utf8")));
}
