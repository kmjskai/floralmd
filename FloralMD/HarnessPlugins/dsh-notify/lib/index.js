/**
 * dsh-notify — server half.
 *
 * Two capability-seam subscriptions, both forwarding raw facts to the host
 * app via `open -g` (background launch, never steals focus):
 *
 * 1. Background jobs (`jobs` service, `@deepseek-ai/dsh-jobs-local`):
 *    `jobs.onJobDone` fires exactly once per job at its terminal state
 *    (completed/failed/killed) — bash jobs and subagent jobs alike
 *    (`kind === 'subagent'`).
 * 2. Root-session turns (`session/event`): `turn/end` fires once per agent
 *    turn with its ending reason. Only ROOT sessions (the ones the GUI user
 *    talks to) are forwarded — subagent turns are filtered out via the
 *    `agents` registry's `roots()`.
 *
 * The plugin ships NO notification UI: the host app owns wording, sounds,
 * permissions, and focus behavior. This plugin only answers "what finished".
 *
 * Install: copied into $DSH_HOME/profiles/node_modules/dsh-notify and
 * registered via cordis.patch.yml — both managed idempotently by the host at
 * startup (see FloralMD's HarnessPluginManager).
 *
 * @module dsh-notify
 */

import { execFile } from "node:child_process";
import { buildNotifyURL, buildTurnNotifyURL } from "./notify-url.js";

/** Stable Cordis plugin name — must match the cordis.patch.yml entry. */
export const name = "dsh-notify";

/** Services required before this plugin activates. */
export const inject = ["jobs", "agents"];

/** URL scheme of the host app; overridable for other hosts. */
export const HOST_SCHEME = process.env.DSH_NOTIFY_SCHEME ?? "floralmd";

/** Open(1) flags: -g = background launch without activating the app. */
const OPEN_FLAGS = ["-g"];

/**
 * Route one notify URL to the host app. Failures are logged, never thrown —
 * a broken host must not break the harness's bookkeeping.
 */
function openNotifyURL(ctx, url) {
	execFile("/usr/bin/open", [...OPEN_FLAGS, url], (error) => {
		if (error) {
			ctx.logger.warn(
				`dsh-notify: open "${url.slice(0, 120)}…" failed: ${String(error)}`
			);
		}
	});
}

/** Hand one settled job (bash/subagent background work). */
function notifyHost(ctx, job) {
	const url = buildNotifyURL(job, HOST_SCHEME);
	if (url === null) return;
	openNotifyURL(ctx, url);
}

/**
 * Session title for notifications: the first user message's text, so the
 * banner says which conversation finished (chat-app style).
 */
function sessionTitle(session) {
	const first = session.events?.find((event) => event.type === "user/message");
	const content = first?.data?.content;
	if (!Array.isArray(content)) return "";
	for (const block of content) {
		if (typeof block?.text === "string" && block.text.trim().length > 0) {
			return block.text;
		}
	}
	return "";
}

/** Hand one finished root-session turn. */
function notifyTurn(ctx, session, event) {
	const { turn, reason } = event.data ?? {};
	if (typeof turn !== "number") return;
	const url = buildTurnNotifyURL(
		session.id,
		turn,
		reason?.kind,
		sessionTitle(session),
		HOST_SCHEME
	);
	if (url === null) return;
	openNotifyURL(ctx, url);
}

/** Cordis plugin entry. */
export function apply(ctx) {
	ctx.logger.info("dsh-notify: active (jobs.onJobDone + turn/end → floralmd://notify)");

	ctx.effect(() =>
		ctx.jobs.onJobDone((job) => {
			try {
				notifyHost(ctx, job);
			} catch (error) {
				ctx.logger.warn(`dsh-notify: job handler threw: ${String(error)}`);
			}
		})
	);

	ctx.effect(() =>
		ctx.on("session/event", (session, event) => {
			if (event?.type !== "turn/end") return;
			try {
				// Only root sessions (the GUI user's conversations) notify;
				// subagent turns belong to in-flight work and would mislead.
				if (!ctx.agents.roots().some((agent) => agent.id === session.id)) return;
				notifyTurn(ctx, session, event);
			} catch (error) {
				ctx.logger.warn(`dsh-notify: turn handler threw: ${String(error)}`);
			}
		})
	);
}
