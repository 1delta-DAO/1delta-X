import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { PreFundOp } from "../src";

/**
 * SHAPE PIN: every `PreFundOp` entry against the module's Solidity `enum Op` (declaration
 * order = the on-chain op number in descriptor bits [244,252)), or the module's `OP_*`
 * constants. A reordered or extended enum in a module fails here, not on-chain
 * (`BadOp`), and a table entry for an op the module does not have fails too.
 */
const MODULES = join(dirname(fileURLToPath(import.meta.url)), "../../modules");
const L = (p: string) => join(MODULES, "lending", p);

/** `[table key, source file, contract name]` — the contract whose `enum Op` the entry mirrors. */
const ENUMS: Array<[keyof typeof PreFundOp, string, string]> = [
  ["AaveV2", L("aave-v2/src/AaveV2PreFundModules.sol"), "AaveV2PreFundModule"],
  ["AaveV3", L("aave-v3/src/AaveV3PreFundModules.sol"), "AaveV3PreFundModule"],
  ["AaveV3Credit", L("aave-v3/src/AaveV3CreditModule.sol"), "AaveV3CreditModule"],
  ["AaveV4", L("aave-v4/src/AaveV4PreFundModules.sol"), "AaveV4PreFundModule"],
  ["CompoundV2", L("compound-v2/src/CompoundV2PreFundModules.sol"), "CompoundV2PreFundModule"],
  ["CompoundV2Native", L("compound-v2/src/CompoundV2PreFundModules.sol"), "CompoundV2NativePreFundModule"],
  ["CompoundV3", L("compound-v3/src/CompoundV3PreFundModules.sol"), "CometPreFundModule"],
  ["Venus", L("venus/src/VenusPreFundModules.sol"), "VenusPreFundModule"],
  ["Silo", L("silo/src/SiloPreFundModules.sol"), "SiloPreFundModule"],
  ["Exactly", L("exactly/src/ExactlyPreFundModules.sol"), "ExactlyPreFundModule"],
  ["MorphoBlue", L("morpho-blue/src/MorphoBluePreFundModules.sol"), "MorphoBluePreFundModule"],
  ["MorphoMidnight", L("morpho-midnight/src/MidnightPreFundModules.sol"), "MidnightPreFundModule"],
  ["LiquityV2", L("liquity-v2/src/LiquityV2PreFundModules.sol"), "LiquityV2PreFundModule"],
  ["River", L("river/src/RiverPreFundModules.sol"), "RiverPreFundModule"],
  ["Teller", L("teller/src/TellerPreFundModules.sol"), "TellerPreFundModule"],
  ["Lista", L("lista/src/ListaPreFundModules.sol"), "ListaPreFundModule"],
  ["ListaBroker", L("lista/src/ListaBrokerModule.sol"), "ListaBrokerModule"],
  ["EulerV2", L("euler-v2/src/EulerV2PreFundModules.sol"), "EulerV2PreFundModule"],
  ["EulerV2Operator", L("euler-v2/src/EulerV2OperatorModule.sol"), "EulerV2OperatorModule"],
  ["DolomiteOperator", L("dolomite/src/DolomiteOperatorModule.sol"), "DolomiteOperatorModule"],
  ["Fluid", L("fluid/src/FluidPreFundModules.sol"), "FluidPreFundModule"],
  ["GearboxCredit", L("gearbox-v3/src/GearboxV3PreFundModules.sol"), "GearboxCreditPreFundModule"],
  ["GearboxPool", L("gearbox-v3/src/GearboxV3PreFundModules.sol"), "GearboxPoolPreFundDepositModule"],
];

/** The members of `enum Op` inside `contract <name>` (comments stripped), in declaration order. */
function enumOp(file: string, contract: string): string[] {
  const src = readFileSync(file, "utf8");
  const at = src.search(new RegExp(`\\bcontract\\s+${contract}\\b`));
  if (at < 0) throw new Error(`${contract} not in ${file}`);
  const next = src.slice(at + 1).search(/\n(?:abstract\s+)?contract\s+\w+/);
  const body = next < 0 ? src.slice(at) : src.slice(at, at + 1 + next);
  const m = /enum\s+Op\s*\{([^}]*)\}/.exec(body);
  if (!m) throw new Error(`no enum Op in ${contract}`);
  return m[1]!
    .replace(/\/\/[^\n]*/g, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
}

describe("PreFundOp mirrors each module's Solidity enum Op", () => {
  it.each(ENUMS)("%s ↔ %s", (key, file, contract) => {
    const members = enumOp(file, contract);
    expect(Object.fromEntries(members.map((name, i) => [name, i]))).toEqual(PreFundOp[key]);
  });

  it("the bridge-out modules: LZ OP_SEND / OP_FEE_CREDIT; Across and CCTP have the one send op", () => {
    const lz = readFileSync(join(MODULES, "bridge/src/out/LzOftBridgeOutModule.sol"), "utf8");
    const c = (name: string) => Number(new RegExp(`uint256 public constant ${name} = (\\d+);`).exec(lz)![1]);
    expect(PreFundOp.LzOftBridgeOut).toEqual({ Send: c("OP_SEND"), FeeCredit: c("OP_FEE_CREDIT") });
    expect(PreFundOp.AcrossBridgeOut).toEqual({ Send: 0 });
    expect(PreFundOp.CctpBridgeOut).toEqual({ Send: 0 });
  });

  it("every table entry is pinned", () => {
    const pinned = new Set<string>([...ENUMS.map((e) => e[0]), "LzOftBridgeOut", "AcrossBridgeOut", "CctpBridgeOut"]);
    expect(Object.keys(PreFundOp).filter((k) => !pinned.has(k))).toEqual([]);
  });
});
