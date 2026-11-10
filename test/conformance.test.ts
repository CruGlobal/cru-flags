/**
 * The shared conformance cases (`conformance/cases.json`), run against this
 * client. Every client in the repository runs the same cases against the same
 * server, `conformance/server.py`. See `conformance/README.md`.
 */
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { CruFlags, type CruFlagsOptions } from "../src/index.js";

interface Step {
  readonly do: "ready" | "refresh";
  readonly enabled?: Readonly<Record<string, boolean>>;
  readonly requests?: number;
  readonly ifNoneMatch?: string | null;
  readonly events?: readonly string[];
}

interface Case {
  readonly name: string;
  readonly url?: boolean;
  readonly steps: readonly Step[];
}

interface SeenRequest {
  readonly headers: Readonly<Record<string, string>>;
}

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const { cases } = JSON.parse(
  readFileSync(join(ROOT, "conformance", "cases.json"), "utf8"),
) as { cases: Case[] };

let server: ChildProcessByStdio<Writable, Readable, null>;
let base: string;

beforeAll(async () => {
  server = spawn("python3", [join(ROOT, "conformance", "server.py")], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  const line = await new Promise<string>((resolve, reject) => {
    const lines = createInterface({ input: server.stdout });
    lines.once("line", (first) => {
      lines.close();
      resolve(first);
    });
    server.once("error", reject);
    server.once("exit", (code) => {
      reject(new Error(`conformance server exited with ${String(code)}`));
    });
  });
  base = `http://127.0.0.1:${line.split(" ")[1] ?? ""}`;
});

afterAll(() => {
  // The server exits when its stdin closes.
  server.stdin.end();
});

async function requestsSeen(name: string, run: string): Promise<SeenRequest[]> {
  const response = await fetch(`${base}/log/${name}/${run}`);
  return (await response.json()) as SeenRequest[];
}

describe("conformance", () => {
  it.each(cases)("$name", async (testCase) => {
    const run = randomUUID();
    const url =
      testCase.url === false
        ? undefined
        : `${base}/flags/${testCase.name}/${run}`;
    const events: string[] = [];
    const options: CruFlagsOptions = {
      pollSeconds: 3600,
      fetchTimeoutMs: 1000,
      refreshMode: "background",
      onError: (event) => events.push(event.kind),
      ...(url === undefined ? {} : { url }),
    };

    const savedUrl = process.env.CRU_FLAGS_URL;
    delete process.env.CRU_FLAGS_URL;
    const client = new CruFlags(options);
    try {
      for (const [index, step] of testCase.steps.entries()) {
        const where = `${testCase.name} step ${index} (${step.do})`;
        if (step.do === "ready") {
          await client.ready();
        } else {
          await client.refresh({ force: true });
        }

        for (const [name, expected] of Object.entries(step.enabled ?? {})) {
          expect(client.enabled(name), `${where}: enabled(${name})`).toBe(
            expected,
          );
        }
        if (
          url !== undefined &&
          (step.requests !== undefined || step.ifNoneMatch !== undefined)
        ) {
          const seen = await requestsSeen(testCase.name, run);
          if (step.requests !== undefined) {
            expect(seen, `${where}: requests`).toHaveLength(step.requests);
          }
          if (step.ifNoneMatch !== undefined) {
            expect(
              seen.at(-1)?.headers["if-none-match"] ?? null,
              `${where}: If-None-Match`,
            ).toBe(step.ifNoneMatch);
          }
        }
        if (step.events !== undefined) {
          expect(events, `${where}: health events`).toEqual(step.events);
        }
      }
    } finally {
      client.close();
      if (savedUrl !== undefined) process.env.CRU_FLAGS_URL = savedUrl;
    }
  });
});
