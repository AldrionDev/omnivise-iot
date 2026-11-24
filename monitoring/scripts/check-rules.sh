#!/usr/bin/env bash
#
# check-rules.sh [--rules-dir DIR] [--tests-dir DIR] [--expected FILE] [--allowlist FILE]
#
# Rule contract: promtool check + unit tests, alert-only rules (at most 10) with
# severity in {warning, critical} and summary/description annotations, a firing AND
# an explicit non-firing (exp_alerts: []) test case per alert, TargetDown job set ==
# enabled expected jobs in every environment, and the domain-metric allowlist.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rules_dir="$MON_DIR/rules" tests_dir="$MON_DIR/rules/tests"
expected="$MON_DIR/expected-targets.yaml" allowlist="$MON_DIR/metric-allowlist.txt"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rules-dir) rules_dir="$2"; shift 2 ;;
    --tests-dir) tests_dir="$2"; shift 2 ;;
    --expected) expected="$2"; shift 2 ;;
    --allowlist) allowlist="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

YQ="$(tool yq)"; JQ="$(tool jq)"; PROMTOOL="$(tool promtool)"
mapfile -t rule_files < <(find "$rules_dir" -maxdepth 1 -type f -name '*.rules.yaml' | LC_ALL=C sort)
mapfile -t test_files < <(find "$tests_dir" -maxdepth 1 -type f -name '*.test.yaml' | LC_ALL=C sort)
[[ ${#rule_files[@]} -gt 0 ]] || die "no *.rules.yaml in $rules_dir"
[[ ${#test_files[@]} -gt 0 ]] || die "no *.test.yaml in $tests_dir"

"$PROMTOOL" check rules "${rule_files[@]}" >&2
"$PROMTOOL" test rules "${test_files[@]}" >&2

rules_json="$("$YQ" -o=json -I=0 ea '[.groups[].rules[]]' "${rule_files[@]}" | "$JQ" -s 'add')"
tests_json="$("$YQ" -o=json -I=0 ea '[.tests[].alert_rule_test[]?]' "${test_files[@]}" | "$JQ" -s 'add')"

failures="$("$JQ" -n --argjson rules "$rules_json" --argjson tests "$tests_json" '
  [ ($rules | length) as $n | if $n > 10 then "\($n) rules defined, at most 10 allowed" else empty end,
    ($rules[] | select(.alert == null) | "recording rule \(.record) is not allowed (alerts only)"),
    ($rules[] | select(.alert != null)
      | ( select((.labels.severity // "") | IN("warning","critical") | not)
          | "alert \(.alert): severity must be warning or critical" ),
        ( select(((.annotations.summary // "") == "") or ((.annotations.description // "") == ""))
          | "alert \(.alert): summary and description annotations are required" )),
    ([$rules[] | .alert // empty] | group_by(.) | map(select(length > 1))[] | "duplicate alert name \(.[0])"),
    ($rules[] | .alert // empty | . as $a
      | ([$tests[] | select(.alertname == $a)]) as $cases
      | ( if ([$cases[] | select((.exp_alerts // []) | length > 0)] | length) == 0
          then "alert \($a): no firing test case (non-empty exp_alerts)" else empty end ),
        ( if ([$cases[] | select(has("exp_alerts") and (.exp_alerts | length) == 0)] | length) == 0
          then "alert \($a): no explicit non-firing test case (exp_alerts: [])" else empty end ))
  ]')"

# TargetDown job alternation must equal the enabled job set of every environment.
target_expr="$("$JQ" -r '[.[] | select(.alert == "TargetDown") | .expr] | if length == 1 then .[0] else "" end' <<<"$rules_json")"
if [[ -z "$target_expr" ]]; then
  failures="$("$JQ" -c '. + ["exactly one TargetDown alert is required"]' <<<"$failures")"
else
  alternation="$(sed -nE 's/^[[:space:]]*up\{job=~"([a-z0-9|-]+)"\}[[:space:]]*==[[:space:]]*0[[:space:]]*$/\1/p' <<<"$target_expr")"
  if [[ -z "$alternation" ]]; then
    failures="$("$JQ" -c '. + ["TargetDown expr must be exactly up{job=~\"<a|b|...>\"} == 0 with plain job names"]' <<<"$failures")"
  else
    rule_jobs="$(tr '|' '\n' <<<"$alternation" | LC_ALL=C sort | "$JQ" -R . | "$JQ" -sc .)"
    for env in $("$YQ" '.environments | keys | .[]' "$expected"); do
      env_jobs="$(E="$env" "$YQ" -o=json -I=0 'explode(.) | [.environments[strenv(E)].enabled[].job]' "$expected" \
        | "$JQ" -c 'sort')"
      if [[ "$env_jobs" != "$rule_jobs" ]]; then
        failures="$("$JQ" -c --arg m "TargetDown jobs $rule_jobs != enabled jobs of $env $env_jobs" '. + [$m]' <<<"$failures")"
      fi
    done
  fi
fi

count="$("$JQ" 'length' <<<"$failures")"
if [[ "$count" -gt 0 ]]; then
  "$JQ" -r '.[] | "FAIL [rules] \(.)"' <<<"$failures" >&2
  die "rule contract: $count failure(s)"
fi

"$JQ" -c '[.[] | {source: ("rule " + (.alert // .record)), expr: .expr}]' <<<"$rules_json" \
  | python3 "$MON_SCRIPTS_DIR/promql_policy.py" --allowlist "$allowlist" \
  || die "rule contract: domain-metric policy violation"

log "rule contract OK ($("$JQ" 'length' <<<"$rules_json") alerts)"
