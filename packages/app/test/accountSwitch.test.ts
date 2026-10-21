import { describe, expect, it } from "vitest";

import { accountSwitched } from "../src/wallet/useWallet";

const A = "0x00000000000000000000000000000000000000Aa";
const B = "0x00000000000000000000000000000000000000bB";

describe("accountSwitched: when a wallet event reloads the app", () => {
  it("only on a move from one account to a different one", () => {
    expect(accountSwitched(A, B)).toBe(true);
    expect(accountSwitched(null, A)).toBe(false); // first connect
    expect(accountSwitched(A, undefined)).toBe(false); // disconnect / locked
    expect(accountSwitched(A, null)).toBe(false);
    expect(accountSwitched(A, A.toLowerCase())).toBe(false); // same account re-announced, other casing
  });
});
