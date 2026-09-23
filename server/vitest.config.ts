import { defineConfig } from "vitest/config";

// Headless, no AWS (DESIGN §4). The default reporter already prints one summary line per
// file on green and expands only failures; `make server-test` forces colour off and runs in
// `run` mode so the suite exits with a code. `server/README.md` says how to turn detail on.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
