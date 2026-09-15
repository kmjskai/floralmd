/**
 * dsh-notify — URL construction, pure and testable.
 *
 * The plugin deliberately carries NO copy: it ships raw job facts
 * (kind/label/status/detail/duration) in a `floralmd://notify` URL and lets
 * the host app (FloralMD) own wording, sounds, and permission handling.
 * This keeps the plugin thin and the host's UX logic in one place.
 */

/** Longest label we forward; bash commands can be huge and URLs must stay sane. */
export const MAX_LABEL_LENGTH = 300;

/** Longest session title we forward (derived from the first user message). */
export const MAX_TITLE_LENGTH = 40;

/** Longest detail line we forward. */
export const MAX_DETAIL_LENGTH = 200;

/** Forwarded job statuses: only terminal ones reach onJobDone, but filter anyway. */
const TERMINAL_STATUSES = new Set(["completed", "failed", "killed"]);

/** Turn-ending reasons worth telling the user about. */
export const TERMINAL_TURN_REASONS = new Set([
	"completed",
	"error",
	"blocked",
	"max-tokens",
	"aborted"
]);

/**
 * Build a `notify` URL for one finished root-session turn (`turn/end`).
 * Carries no copy either: session id, turn number, and the end reason.
 *
 * @param sessionId - the root session that finished its turn.
 * @param turn - the turn number that ended.
 * @param reasonKind - one of {@link TERMINAL_TURN_REASONS}.
 * @param title - optional session title (derived from the first user message).
 * @param scheme - URL scheme of the host app.
 */
export function buildTurnNotifyURL(sessionId, turn, reasonKind, title = "", scheme = "floralmd") {
	if (sessionId == null || turn == null) return null;
	if (!TERMINAL_TURN_REASONS.has(reasonKind)) return null;
	const params = new URLSearchParams();
	params.set("kind", "turn");
	params.set("id", String(sessionId));
	params.set("turn", String(turn));
	params.set("status", String(reasonKind));
	if (title.length > 0) params.set("title", trimText(title, MAX_TITLE_LENGTH));
	return `${scheme}://notify?${params.toString()}`;
}

/**
 * Build a `notify` URL for one settled background job.
 *
 * @param scheme - URL scheme of the host app (defaults to `floralmd`).
 * @param job - the `JobSnapshot` delivered by `jobs.onJobDone`.
 * @returns the full notify URL, or null for non-terminal/no-label jobs.
 */
export function buildNotifyURL(job, scheme = "floralmd") {
	if (job == null) return null;
	if (!TERMINAL_STATUSES.has(job.status)) return null;
	const label = trimText(job.label, MAX_LABEL_LENGTH);
	if (label.length === 0) return null;

	const params = new URLSearchParams();
	params.set("kind", job.kind ?? "job");
	params.set("label", label);
	params.set("status", job.status);
	if (typeof job.id === "string" && job.id.length > 0) params.set("id", job.id);
	if (typeof job.detail === "string" && job.detail.length > 0) {
		params.set("detail", trimText(job.detail, MAX_DETAIL_LENGTH));
	}
	if (typeof job.startedAt === "number" && typeof job.finishedAt === "number") {
		params.set("durationMs", String(Math.max(0, job.finishedAt - job.startedAt)));
	}
	return `${scheme}://notify?${params.toString()}`;
}

/** Collapse whitespace and clamp length (URLs must stay single-line). */
function trimText(text, maxLength) {
	const collapsed = String(text).replace(/\s+/g, " ").trim();
	return collapsed.length <= maxLength ? collapsed : `${collapsed.slice(0, maxLength)}…`;
}
