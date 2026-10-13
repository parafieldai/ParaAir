#!/bin/bash
# GitHub repository settings that ParaAir's CI/CD relies on, as code. See docs/ci-cd.md.
#
#   scripts/github-settings.sh            dry run (default): read-only GET requests, then print every
#                                         write it would make, with its JSON body
#   scripts/github-settings.sh --apply    perform the writes
#
# Idempotent: every write is a PUT/PATCH of the full desired state, or a POST only when the
# ruleset or deployment policy does not exist yet. Needs `gh` signed in as an admin of both
# repositories (the operator account). Plan limits on the private repository (rulesets, required
# reviewers, environment secrets need GitHub Pro/Team for private repos) are reported and skipped,
# not treated as failures. Uses bash 3.2, gh and jq.
set -euo pipefail

OWNER=parafieldai
PUBLIC_REPO=ParaAir
PRIVATE_REPO=paraair-cloud
MAINTAINER=parafieldai
# Job names in .github/workflows/ci.yml. Rename a job there and here in the same change.
REQUIRED_CHECKS=(swift native app contract site)
# Every action the workflows of both repositories use (all GitHub-owned, pinned by SHA).
ALLOWED_ACTIONS=(actions/cache actions/checkout actions/setup-go actions/setup-node actions/upload-artifact)
GITHUB_ACTIONS_APP_ID=15368 # GET /apps/github-actions; status checks must come from Actions
ADMIN_ROLE_ID=5             # repository role "admin" in ruleset bypass_actors
API_VERSION=2022-11-28

root="$(cd "$(dirname "$0")/.." && pwd)"
apply=0
for argument in "$@"; do
  case "$argument" in
    --apply) apply=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: $0 [--apply]" >&2; exit 2 ;;
  esac
done
for tool in gh jq; do command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }; done
errors_file="$(mktemp)"
trap 'rm -f "$errors_file"' EXIT

planned=0 applied=0 skipped=0 failed=0
failures=()
mode="DRY RUN (nothing is changed; rerun with --apply)"
(( apply )) && mode="APPLY"
echo "GitHub settings for $OWNER/$PUBLIC_REPO (public) and $OWNER/$PRIVATE_REPO (private): $mode"

# api_get PATH: prints the JSON body; on failure prints gh's message to stderr and returns 1.
api_get() {
  echo "    GET /$1" >&2
  gh api -H "X-GitHub-Api-Version: $API_VERSION" "$1"
}

# write SOFT METHOD PATH BODY DESCRIPTION. SOFT=1: a refusal (plan limit) is reported, not a failure.
write() {
  local soft="$1" method="$2" path="$3" body="$4" what="$5" error
  planned=$((planned + 1))
  echo "--> $what"
  echo "    $method /$path"
  [[ -z "$body" ]] || printf '%s\n' "$body" | jq -c . | sed 's/^/    body: /'
  (( apply )) || return 0
  if [[ -n "$body" ]]; then
    error="$(printf '%s' "$body" | gh api --method "$method" -H "X-GitHub-Api-Version: $API_VERSION" "$path" --input - 2>&1 >/dev/null)" && { applied=$((applied + 1)); echo "    ok"; return 0; }
  else
    error="$(gh api --method "$method" -H "X-GitHub-Api-Version: $API_VERSION" "$path" 2>&1 >/dev/null)" && { applied=$((applied + 1)); echo "    ok"; return 0; }
  fi
  error="$(printf '%s' "$error" | tr '\n' ' ')"
  if [[ "$soft" == 1 ]]; then
    skipped=$((skipped + 1)); echo "    SKIPPED (not available for this repository or plan): $error"
  else
    failed=$((failed + 1)); failures+=("$method /$path: $error"); echo "    FAILED: $error"
  fi
}

skip() { skipped=$((skipped + 1)); echo "--> SKIPPED: $1"; }

# Checks that the workflows use only the allowed actions, so the allow-list cannot drift silently.
check_allowed_actions() {
  local used action allowed found unknown=0
  used="$(cat "$root"/.github/workflows/*.yml "$root"/cloud/.github/workflows/*.yml 2>/dev/null \
    | sed -n 's/^[[:space:]-]*uses:[[:space:]]*\([^@[:space:]]*\)@\([^[:space:]]*\).*/\1 \2/p' | sort -u)"
  while read -r action ref; do
    [[ -n "$action" ]] || continue
    case "$action" in ./*) continue ;; esac
    found=0
    for allowed in "${ALLOWED_ACTIONS[@]}"; do
      [[ "$action" == "$allowed" || "$action" == "$allowed"/* ]] && found=1
    done
    (( found )) || { echo "    WARNING: workflows use $action, which is not in ALLOWED_ACTIONS" >&2; unknown=1; }
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "    WARNING: $action@$ref is not pinned to a full commit SHA" >&2; unknown=1; }
  done <<<"$used"
  if (( unknown == 0 )); then echo "    workflows use only allowed actions, all pinned to full SHAs"; fi
}

patterns_json() { printf '%s\n' "${ALLOWED_ACTIONS[@]}" | sed 's/$/@*/' | jq -R . | jq -sc .; }

# ruleset_main CHECK...: the default-branch ruleset with these required status checks.
ruleset_main() {
  local checks
  checks="$(printf '%s\n' "$@" | jq -R --argjson app "$GITHUB_ACTIONS_APP_ID" '{context: ., integration_id: $app}' | jq -sc .)"
  jq -nc --argjson checks "$checks" --argjson admin "$ADMIN_ROLE_ID" '{
    name: "main", target: "branch", enforcement: "active",
    bypass_actors: [{actor_id: $admin, actor_type: "RepositoryRole", bypass_mode: "always"}],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0, dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false, require_last_push_approval: false,
        required_review_thread_resolution: true, allowed_merge_methods: ["squash"]}},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false, do_not_enforce_on_create: false,
        required_status_checks: $checks}}
    ]}'
}

ruleset_tags() {
  jq -nc --argjson admin "$ADMIN_ROLE_ID" '{
    name: "release tags", target: "tag", enforcement: "active",
    bypass_actors: [{actor_id: $admin, actor_type: "RepositoryRole", bypass_mode: "always"}],
    conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
    rules: [{type: "creation"}, {type: "update", parameters: {update_allows_fetch_and_merge: false}},
            {type: "deletion"}, {type: "non_fast_forward"}]}'
}

# upsert_ruleset SOFT REPO BODY: PUT over the ruleset with the same name, else POST.
upsert_ruleset() {
  local soft="$1" repo="$2" body="$3" name existing id
  name="$(jq -r .name <<<"$body")"
  echo "    GET /repos/$OWNER/$repo/rulesets"
  if ! existing="$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$OWNER/$repo/rulesets?includes_parents=false" 2>"$errors_file")"; then
    local message; message="$(tr '\n' ' ' < "$errors_file")"
    if [[ "$soft" == 1 ]]; then skip "ruleset \"$name\" on $repo: rulesets are not available here ($message)"; return 0; fi
    failed=$((failed + 1)); failures+=("GET rulesets on $repo: $message"); echo "    FAILED: $message"; return 0
  fi
  id="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<<"$existing" | head -n 1)"
  if [[ -n "$id" ]]; then
    write "$soft" PUT "repos/$OWNER/$repo/rulesets/$id" "$body" "ruleset \"$name\" (update id $id)"
  else
    write "$soft" POST "repos/$OWNER/$repo/rulesets" "$body" "ruleset \"$name\" (create)"
  fi
}

# environment SOFT REPO NAME TYPE PATTERN: required reviewer = maintainer, deployments only from
# refs matching PATTERN (TYPE branch or tag). Adds the policy only if it is missing.
environment() {
  local soft="$1" repo="$2" name="$3" type="$4" pattern="$5" body policies
  body="$(jq -nc --argjson id "$maintainer_id" '{wait_timer: 0, prevent_self_review: false,
    reviewers: [{type: "User", id: $id}],
    deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}')"
  write "$soft" PUT "repos/$OWNER/$repo/environments/$name" "$body" "environment \"$name\" on $repo: reviewer $MAINTAINER, $type $pattern only"
  if policies="$(api_get "repos/$OWNER/$repo/environments/$name/deployment-branch-policies" 2>/dev/null)" &&
     jq -e --arg p "$pattern" --arg t "$type" '.branch_policies[] | select(.name == $p and .type == $t)' <<<"$policies" >/dev/null; then
    echo "    deployment policy $type \"$pattern\" already present"
    return 0
  fi
  write "$soft" POST "repos/$OWNER/$repo/environments/$name/deployment-branch-policies" \
    "$(jq -nc --arg p "$pattern" --arg t "$type" '{name: $p, type: $t}')" "environment \"$name\": allow $type \"$pattern\""
}

echo
echo "== Preflight (read-only)"
check_allowed_actions
maintainer_id="$(api_get "users/$MAINTAINER" | jq -r .id)"
echo "    $MAINTAINER user id: $maintainer_id"
visibility="$(api_get "repos/$OWNER/$PUBLIC_REPO" | jq -r .visibility)"
[[ "$visibility" == public ]] || { echo "$OWNER/$PUBLIC_REPO is $visibility, expected public; stopping." >&2; exit 1; }

echo
echo "== $OWNER/$PUBLIC_REPO (public)"
# Squash merge only: one reviewed commit per pull request, linear history on main, and an
# outside contributor's branch history never lands on main. Discussions are left unchanged.
write 0 PATCH "repos/$OWNER/$PUBLIC_REPO" "$(jq -nc '{has_issues: true, has_pull_requests: true,
  pull_request_creation_policy: "all", allow_squash_merge: true, allow_merge_commit: false,
  allow_rebase_merge: false, squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
  allow_update_branch: true, allow_auto_merge: false, delete_branch_on_merge: true}')" \
  "issues and outside pull requests on; squash merge only; delete head branches on merge"
write 0 PATCH "repos/$OWNER/$PUBLIC_REPO" "$(jq -nc '{security_and_analysis: {
  secret_scanning: {status: "enabled"}, secret_scanning_push_protection: {status: "enabled"}}}')" \
  "secret scanning and push protection on"
write 0 PUT "repos/$OWNER/$PUBLIC_REPO/private-vulnerability-reporting" "" "private vulnerability reporting on"
write 0 PUT "repos/$OWNER/$PUBLIC_REPO/actions/permissions" \
  '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' \
  "Actions on; selected actions only; actions must be pinned to full commit SHAs"
write 0 PUT "repos/$OWNER/$PUBLIC_REPO/actions/permissions/selected-actions" \
  "$(jq -nc --argjson p "$(patterns_json)" '{github_owned_allowed: true, verified_allowed: false, patterns_allowed: $p}')" \
  "allowed actions: GitHub-owned plus the explicit list the workflows use"
write 0 PUT "repos/$OWNER/$PUBLIC_REPO/actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' \
  "GITHUB_TOKEN read-only by default; Actions cannot approve pull requests"
write 0 PUT "repos/$OWNER/$PUBLIC_REPO/actions/permissions/fork-pr-contributor-approval" \
  '{"approval_policy":"all_external_contributors"}' \
  "fork pull request workflows wait for maintainer approval for every outside contributor"
upsert_ruleset 0 "$PUBLIC_REPO" "$(ruleset_main "${REQUIRED_CHECKS[@]}")"
upsert_ruleset 0 "$PUBLIC_REPO" "$(ruleset_tags)"
environment 0 "$PUBLIC_REPO" release tag "v*"
environment 0 "$PUBLIC_REPO" production branch main

echo
echo "== $OWNER/$PRIVATE_REPO (private)"
write 1 PATCH "repos/$OWNER/$PRIVATE_REPO" "$(jq -nc '{allow_squash_merge: true, allow_merge_commit: false,
  allow_rebase_merge: false, squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
  delete_branch_on_merge: true}')" "squash merge only; delete head branches on merge"
write 1 PUT "repos/$OWNER/$PRIVATE_REPO/actions/permissions" \
  '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' \
  "Actions on; selected actions only; full-SHA pinning required"
# patterns_allowed applies to public repositories only; every action used here is GitHub-owned.
write 1 PUT "repos/$OWNER/$PRIVATE_REPO/actions/permissions/selected-actions" \
  '{"github_owned_allowed":true,"verified_allowed":false}' "allowed actions: GitHub-owned only"
write 1 PUT "repos/$OWNER/$PRIVATE_REPO/actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' \
  "GITHUB_TOKEN read-only by default; Actions cannot approve pull requests"
write 1 PUT "repos/$OWNER/$PRIVATE_REPO/actions/permissions/fork-pr-workflows-private-repos" \
  '{"run_workflows_from_fork_pull_requests":false}' "no workflow runs for fork pull requests"
# Rulesets on private repositories need GitHub Pro or higher; on Free the GET answers 403 and this is skipped.
upsert_ruleset 1 "$PRIVATE_REPO" "$(ruleset_main worker)"
environment 1 "$PRIVATE_REPO" production branch main

echo
echo "Summary: $planned writes planned; $applied applied, $skipped skipped (plan or availability), $failed failed."
if (( failed )); then printf '  failed: %s\n' "${failures[@]}" >&2; exit 1; fi
(( apply )) || echo "Dry run only. Review the calls above, then run: scripts/github-settings.sh --apply"
