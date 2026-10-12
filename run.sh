#!/usr/bin/env bash
# EvalForge change test for CI: copy production, apply this change, run the suite, report, gate.
# Needs curl and jq (preinstalled on GitHub-hosted runners); gh for the PR comment.
set -euo pipefail

API="${EF_API_URL%/}/api/v1/eng"
AUTH=(-H "Authorization: Bearer ${EF_API_KEY}")
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT" || true; }
api() {   # api METHOD PATH [JSON] -> body; exits on HTTP errors with the server's message
  local m=$1 p=$2 d=${3:-} code body
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' -X "$m" "${API}${p}" "${AUTH[@]}" -H 'Content-Type: application/json' ${d:+--data "$d"})
  if [ "$code" -ge 400 ]; then echo "::error::EvalForge ${m} ${p} → ${code}: $(jq -r '.detail // .' "$body" 2>/dev/null || cat "$body")" >&2; exit 1; fi
  cat "$body"; rm -f "$body"
}

# 1. what changed
req=$(jq -n --arg sha "$EF_CODE_SHA" --arg note "${EF_NOTE:0:200}" --argjson trials "${EF_TRIALS:-1}" \
  '{code_sha: $sha, note: $note, trials: $trials}')
[ -n "${EF_MODEL:-}" ] && req=$(jq --arg v "$EF_MODEL" '. + {model: $v}' <<<"$req")
[ -n "${EF_PROVIDER:-}" ] && req=$(jq --arg v "$EF_PROVIDER" '. + {provider: $v}' <<<"$req")
if [ -n "${EF_PROMPT_FILE:-}" ]; then
  [ -f "$EF_PROMPT_FILE" ] || { echo "::error::prompt-file not found: $EF_PROMPT_FILE" >&2; exit 1; }
  req=$(jq --rawfile v "$EF_PROMPT_FILE" '. + {system_prompt: $v}' <<<"$req")
fi

# 2. start
start=$(api POST "/projects/${EF_PROJECT}/test-change" "$req")
T=$(jq -r .test_id <<<"$start"); LABEL=$(jq -r .label <<<"$start"); BASE=$(jq -r .baseline_label <<<"$start")
URL="${EF_APP_URL%/}/#/change/${T}"
echo "EvalForge: testing ${LABEL} against production ${BASE} → ${URL}"
out test-id "$T"; out report-url "$URL"

# 3. wait for every case, then (briefly) for the automatic diagnoses of regressions
deadline=$(( $(date +%s) + ${EF_TIMEOUT_MIN:-20} * 60 ))
while :; do
  t=$(api GET "/change-tests/${T}")
  done_=$(jq '.progress.done' <<<"$t"); total=$(jq '.progress.total' <<<"$t")
  diag=$(jq '[.rows[] | select(.rca != null and (.rca.status == "queued" or .rca.status == "running"))] | length' <<<"$t")
  pending=$(jq -r '.gate.verdict' <<<"$t")
  echo "  ${done_}/${total} cases done$([ "$diag" -gt 0 ] && echo ", ${diag} diagnoses running")"
  if [ "$done_" -ge "$total" ] && [ "$pending" != "pending" ] && [ "$diag" -eq 0 ]; then break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    if [ "$done_" -ge "$total" ]; then echo "::warning::diagnoses still running; reporting without them"; break; fi
    echo "::error::timed out after ${EF_TIMEOUT_MIN} min (${done_}/${total} done). See ${URL}" >&2; exit 1
  fi
  sleep ${EF_POLL_SECONDS:-10}
done

# 4. summarise
VERDICT=$(jq -r '.gate.verdict' <<<"$t"); out verdict "$VERDICT"
summary=$(jq -r --arg url "$URL" --arg label "$LABEL" --arg base "$BASE" '
  def p: if . == null then "–" else (. * 100 | round | tostring) + "%" end;
  (if .gate.verdict == "ready" then "### ✅ EvalForge: **ready to ship**" else "### ⛔ EvalForge: **blocked**" end),
  "",
  "`\($label)` vs production `\($base)` · **\(.candidate_summary.passed)/\(.candidate_summary.cases)** passing (was \(.baseline_summary.passed)) · score \(.baseline_summary.avg_score | p) → \(.candidate_summary.avg_score | p) · **\(.counts.regressed)** regressed, \(.counts.fixed) fixed",
  "",
  (.gate.rules[] | "- \(if .passed then "✓" else "✗" end) \(.rule)\(if .detail then ": \(.detail)" else "" end)"),
  "",
  (if ([.rows[] | select(.kind == "regressed")] | length) > 0 then
     "| Regressed case | Cause | Suggested fix |", "|---|---|---|",
     (.rows[] | select(.kind == "regressed") |
       "| \(.title) | \(.rca.result.diagnosis.cause // "–") \(.rca.result.diagnosis.kind // "" | ascii_downcase | gsub("_"; " ")) | \((.rca.result.fix.summary // "open in EvalForge") | gsub("\\|"; "/") | gsub("\n"; " ")) |"),
     ""
   else empty end),
  "[Open the full comparison and diagnosis in EvalForge →](\($url))"' <<<"$t")
report=$(api GET "/change-tests/${T}/report.md")
body="<!-- evalforge:${EF_PROJECT} -->
${summary}

<details><summary>Full change report</summary>

${report:0:50000}
</details>"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$body" >> "$GITHUB_STEP_SUMMARY"
printf '%s\n' "$summary"

# 5. PR comment (create, or update ours)
PR=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)
if [ "${EF_COMMENT:-true}" = "true" ] && [ -n "$PR" ] && command -v gh >/dev/null; then
  cid=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" --paginate \
        --jq ".[] | select(.body | startswith(\"<!-- evalforge:${EF_PROJECT} -->\")) | .id" 2>/dev/null | tail -1 || true)
  if [ -n "$cid" ]; then gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${cid}" -f body="$body" >/dev/null && echo "updated PR comment"
  else gh api "repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" -f body="$body" >/dev/null && echo "posted PR comment"; fi \
    || echo "::warning::couldn't comment on the PR (give the job 'pull-requests: write')"
fi

# 6. gate
if [ "$VERDICT" = "blocked" ] && [ "${EF_FAIL_ON_BLOCKED:-true}" = "true" ]; then
  echo "::error::EvalForge release gate: blocked. ${URL}" >&2; exit 1
fi
echo "EvalForge release gate: ${VERDICT}"
