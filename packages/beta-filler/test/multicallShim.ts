import { QUOTER_V2_ABI } from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, type Address, type Hex } from "viem";

import { FACTORY_GET_POOL_ABI, POOL_STATE_ABI } from "../src/poolGraph";

type Call = { target: Address; allowFailure: boolean; callData: Hex };
export type ShimHandler = (a: { address: Address; functionName: string; args: readonly unknown[] }) => unknown | Promise<unknown>;

const ABIS = [QUOTER_V2_ABI, FACTORY_GET_POOL_ABI, POOL_STATE_ABI] as const;

/**
 * A mock Multicall3 `aggregate3`: decodes every call against the quoter / factory /
 * pool ABIs, runs `handler` (a throw = that call reverted) and re-encodes the result —
 * so a test chain's existing per-call mocks serve batched reads unchanged.
 */
export async function aggregate3(calls: readonly Call[], handler: ShimHandler): Promise<Array<{ success: boolean; returnData: Hex }>> {
  const out: Array<{ success: boolean; returnData: Hex }> = [];
  for (const c of calls) {
    let decoded: { abi: (typeof ABIS)[number]; functionName: string; args: readonly unknown[] } | undefined;
    for (const abi of ABIS) {
      try {
        const d = decodeFunctionData({ abi, data: c.callData });
        decoded = { abi, functionName: d.functionName, args: (d.args ?? []) as readonly unknown[] };
        break;
      } catch {
        // next ABI
      }
    }
    if (!decoded) throw new Error(`multicall shim: unknown call ${c.callData.slice(0, 10)}`);
    try {
      const result = await handler({ address: c.target, functionName: decoded.functionName, args: decoded.args });
      out.push({ success: true, returnData: encodeFunctionResult({ abi: decoded.abi, functionName: decoded.functionName, result } as never) });
    } catch {
      out.push({ success: false, returnData: "0x" });
    }
  }
  return out;
}
