// The validation benchmark's Node.js program (tools/validate_compare_check.sh): protovalidate-es
// over the schema of bench/validate/proto.
//
//   node main.js [--quick] <directory>
//
// The directory holds `set.binpb`, the schema's FileDescriptorSet with its imports, and each
// case's encoded message, which the check writes with buf. protobuf-es code is the schema's
// descriptors, and generated code builds them from an embedded descriptor in the same way, so
// the program reads them from the set with no code to generate. It times two things as
// bench/measure.zig does, the median nanoseconds of one call of each: `validate` of the message
// decoded once, and `fromBinary` of its octets with `validate` of what it gives. It prints a row
// for each case with its verdict: "valid", or "invalid:" and the rule ids of the violations in
// order.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createFileRegistry, fromBinary } from "@bufbuild/protobuf";
import { FileDescriptorSetSchema } from "@bufbuild/protobuf/wkt";
import { createValidator } from "@bufbuild/protovalidate";

// bench/constants.zig's settings: 11 batches of about 20 ms, or 3 of about 1 ms with --quick.
const full = { runs: 11, batchNs: 20_000_000n };
const quick = { runs: 3, batchNs: 1_000_000n };
// Calibration doubles the iterations at most this many times.
const doublingsMax = 40;

const cases = [
  ["small valid", "small_valid.binpb", "Small"],
  ["small invalid", "small_invalid.binpb", "Small"],
  ["medium valid", "medium_valid.binpb", "Medium"],
  ["medium invalid", "medium_invalid.binpb", "Medium"],
  ["rules valid", "rules_valid.binpb", "Rules"],
  ["rules invalid", "rules_invalid.binpb", "Rules"],
];

function timeBatch(run, iterations) {
  const start = process.hrtime.bigint();
  run(iterations);
  return process.hrtime.bigint() - start;
}

function medianNs(settings, run) {
  let iterations = 1;
  for (let i = 0; i < doublingsMax; i++) {
    if (timeBatch(run, iterations) >= settings.batchNs) break;
    iterations *= 2;
  }
  timeBatch(run, iterations);
  const perIteration = [];
  for (let i = 0; i < settings.runs; i++) perIteration.push(Number(timeBatch(run, iterations)) / iterations);
  perIteration.sort((a, b) => a - b);
  return perIteration[Math.floor(perIteration.length / 2)];
}

function verdictOf(result) {
  if (result.kind === "valid") return "valid";
  if (result.kind === "error") throw result.error;
  return "invalid:" + result.violations.map((violation) => violation.ruleId).sort().join(",");
}

function main() {
  const args = process.argv.slice(2);
  const settings = args.includes("--quick") ? quick : full;
  const directory = args.find((arg) => arg !== "--quick");
  if (directory === undefined) throw new Error("usage: node main.js [--quick] <directory>");
  const registry = createFileRegistry(fromBinary(FileDescriptorSetSchema, readFileSync(join(directory, "set.binpb"))));
  // One validator for every call, as a server keeps one: it plans each type's rules once.
  const validator = createValidator();
  const lines = ["| case | verdict | validate ns/op | decode and validate ns/op |", "| --- | --- | ---: | ---: |"];
  for (const [name, file, type] of cases) {
    const schema = registry.getMessage(`bench.validate.v1.${type}`);
    const bytes = readFileSync(join(directory, file));
    const message = fromBinary(schema, bytes);
    const verdict = verdictOf(validator.validate(schema, message));
    let sink = 0;
    const ns = medianNs(settings, (n) => {
      for (let i = 0; i < n; i++) sink += validator.validate(schema, message).kind.length;
    });
    const bothNs = medianNs(settings, (n) => {
      for (let i = 0; i < n; i++) sink += validator.validate(schema, fromBinary(schema, bytes)).kind.length;
    });
    if (sink === 0) throw new Error("no validation ran");
    lines.push(`| ${name} | ${verdict} | ${ns.toFixed(1)} | ${bothNs.toFixed(1)} |`);
  }
  console.log(lines.join("\n"));
}

main();
