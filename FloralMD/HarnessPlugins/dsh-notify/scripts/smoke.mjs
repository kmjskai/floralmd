// dsh-notify smoke test: URL construction edge cases (no harness needed).
import assert from "node:assert/strict";
import { buildNotifyURL, buildTurnNotifyURL } from "../lib/notify-url.js";

// Terminal states forward.
const done = buildNotifyURL({
	id: "bash-7",
	kind: "bash",
	label: "npm run build",
	status: "completed",
	startedAt: 1000,
	finishedAt: 13000,
});
assert.ok(done.startsWith("floralmd://notify?"), done);
assert.ok(done.includes("kind=bash"), done);
assert.ok(done.includes("label=npm+run+build"), done);
assert.ok(done.includes("status=completed"), done);
assert.ok(done.includes("durationMs=12000"), done);
assert.ok(done.includes("id=bash-7"), done);

// Failed with detail.
const failed = buildNotifyURL({
	id: "bash-8",
	kind: "bash",
	label: "run tests",
	status: "failed",
	detail: "exit code: 3",
	startedAt: 1000,
	finishedAt: 2000,
});
assert.ok(failed.includes("status=failed"), failed);
assert.ok(failed.includes("detail=exit+code%3A+3"), failed);

// Non-terminal states are dropped.
assert.equal(buildNotifyURL({ kind: "bash", label: "x", status: "running" }), null);
assert.equal(buildNotifyURL({ kind: "bash", label: "x", status: "stopping" }), null);
assert.equal(buildNotifyURL(null), null);

// Blank label is dropped (nothing useful to say).
assert.equal(buildNotifyURL({ kind: "bash", label: "  ", status: "completed" }), null);

// Long labels collapse whitespace and clamp.
const long = buildNotifyURL({
	kind: "bash",
	label: "a".repeat(500) + "   " + "b".repeat(500),
	status: "completed",
});
assert.ok(long.length < 700, String(long.length));
assert.ok(!long.includes("\n"), long);

// Custom scheme.
const custom = buildNotifyURL(
	{ kind: "subagent", label: "research", status: "completed" },
	"myhost"
);
assert.ok(custom.startsWith("myhost://notify?"), custom);

// Turn URLs: kind=turn, turn number, ending reason, optional title.
const turnURL = buildTurnNotifyURL("sess-1", 7, "completed");
assert.equal(
	turnURL,
	"floralmd://notify?kind=turn&id=sess-1&turn=7&status=completed",
	turnURL
);
const titled = buildTurnNotifyURL("sess-1", 7, "completed", "写一个通知插件");
assert.ok(titled.includes("title=%E5%86%99%E4%B8%80%E4%B8%AA%E9%80%9A%E7%9F%A5%E6%8F%92%E4%BB%B6"), titled);
assert.equal(buildTurnNotifyURL("sess-1", 7, "running"), null); // non-terminal
assert.equal(buildTurnNotifyURL(null, 7, "completed"), null);
assert.equal(buildTurnNotifyURL("sess-1", null, "completed"), null);
const turnCustom = buildTurnNotifyURL("sess-1", 3, "error", "", "myhost");
assert.ok(turnCustom.startsWith("myhost://notify?"), turnCustom);

console.log("dsh-notify smoke: all assertions passed");
