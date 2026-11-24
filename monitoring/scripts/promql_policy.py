#!/usr/bin/env python3
"""Fail-closed metric allowlist lint for PromQL expressions.

This is a policy lint, not a PromQL parser. It removes string literals, label
matcher blocks and range/subquery brackets, then classifies the remaining
identifiers as functions/aggregations, keywords, modifier label lists or metric
names. Every metric name must match the allowlist. Anything the lint cannot
classify unambiguously (unknown function, `__name__` matcher, template variable
outside a matcher/range, unexpected character) is reported as an error.

Input (stdin): JSON array of {"source": str, "expr": str}.
Usage: promql_policy.py --allowlist FILE [--print-metrics]
Exit status: 0 = all expressions pass, 1 = violations or unclassifiable input.
"""

import argparse
import json
import re
import sys

FUNCTIONS = {
    "abs", "absent", "absent_over_time", "acos", "acosh", "asin", "asinh", "atan", "atanh",
    "avg_over_time", "ceil", "changes", "clamp", "clamp_max", "clamp_min", "cos", "cosh",
    "count_over_time", "day_of_month", "day_of_week", "day_of_year", "days_in_month", "deg",
    "delta", "deriv", "double_exponential_smoothing", "end", "exp", "floor", "histogram_avg",
    "histogram_count", "histogram_fraction", "histogram_quantile", "histogram_stddev",
    "histogram_stdvar", "histogram_sum", "hour", "idelta", "increase", "irate",
    "label_join", "label_replace", "last_over_time", "ln", "log10", "log2", "mad_over_time",
    "max_over_time", "min_over_time", "minute", "month", "pi", "predict_linear",
    "present_over_time", "quantile_over_time", "rad", "rate", "resets", "round", "scalar",
    "sgn", "sin", "sinh", "sort", "sort_by_label", "sort_by_label_desc", "sort_desc", "sqrt",
    "start", "stddev_over_time", "stdvar_over_time", "sum_over_time", "tan", "tanh", "time",
    "timestamp", "vector", "year",
}
AGGREGATIONS = {
    "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count", "count_values",
    "bottomk", "topk", "quantile", "limitk", "limit_ratio",
}
# Followed by a parenthesised label list (optional for group_left/group_right).
LABEL_LIST_MODIFIERS = {"by", "without", "on", "ignoring", "group_left", "group_right"}
KEYWORDS = {"bool", "offset", "and", "or", "unless", "atan2", "inf", "nan"}

IDENT_START = re.compile(r"[A-Za-z_:]")
IDENT = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")
LABEL_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(r"(0[xX][0-9a-fA-F]+|[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?[a-zA-Z0-9_]*)")
RANGE_CONTENT = re.compile(r"^[0-9A-Za-z_:.$\s]+$")
OPERATOR_CHARS = set("+-*/%^=!<>,()@")


class Unclassifiable(Exception):
    pass


def load_allowlist(path):
    exact, prefixes = set(), []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.endswith("*"):
                prefixes.append(line[:-1])
            else:
                exact.add(line)
    if not exact and not prefixes:
        raise SystemExit(f"empty allowlist: {path}")
    return exact, prefixes


def skip_string(expr, i):
    quote = expr[i]
    i += 1
    while i < len(expr):
        if expr[i] == "\\" and quote != "`":
            i += 2
            continue
        if expr[i] == quote:
            return i + 1
        i += 1
    raise Unclassifiable("unterminated string literal")


def skip_ws(expr, i):
    while i < len(expr) and expr[i].isspace():
        i += 1
    return i


def consume_matchers(expr, i):
    """expr[i] == '{'. Returns index after the matching '}'; rejects __name__ matchers."""
    i += 1
    outside_strings = []
    while i < len(expr):
        ch = expr[i]
        if ch in "\"'`":
            i = skip_string(expr, i)
            outside_strings.append(" ")
            continue
        if ch == "}":
            names = LABEL_NAME.findall("".join(outside_strings))
            if "__name__" in names:
                raise Unclassifiable("__name__ matcher is not allowed (metric name must be explicit)")
            return i + 1
        if ch in "{[":
            raise Unclassifiable(f"unexpected '{ch}' inside label matchers")
        outside_strings.append(ch)
        i += 1
    raise Unclassifiable("unterminated label matcher block")


def consume_range(expr, i):
    """expr[i] == '['. Returns index after ']' (range or subquery)."""
    end = expr.find("]", i)
    if end < 0:
        raise Unclassifiable("unterminated range selector")
    content = expr[i + 1:end]
    if not RANGE_CONTENT.match(content):
        raise Unclassifiable(f"unexpected range selector content '[{content}]'")
    return end + 1


def consume_label_list(expr, i):
    """expr[i] == '('. A modifier label list: label names and commas only."""
    end = expr.find(")", i)
    if end < 0:
        raise Unclassifiable("unterminated label list")
    content = expr[i + 1:end]
    for part in content.split(","):
        part = part.strip()
        if part and not LABEL_NAME.fullmatch(part):
            raise Unclassifiable(f"unexpected label list entry '{part}'")
    return end + 1


def metric_names(expr):
    """Return the metric names referenced by expr, or raise Unclassifiable."""
    names = []
    i = 0
    n = len(expr)
    while i < n:
        ch = expr[i]
        if ch.isspace():
            i += 1
        elif ch == "#":
            newline = expr.find("\n", i)
            i = n if newline < 0 else newline + 1
        elif ch in "\"'`":
            i = skip_string(expr, i)
        elif ch == "{":
            i = consume_matchers(expr, i)
        elif ch == "[":
            i = consume_range(expr, i)
        elif ch.isdigit() or (ch == "." and i + 1 < n and expr[i + 1].isdigit()):
            match = NUMBER.match(expr, i)
            i = match.end()
        elif IDENT_START.match(ch):
            ident = IDENT.match(expr, i).group(0)
            i += len(ident)
            nxt = skip_ws(expr, i)
            following = expr[nxt] if nxt < n else ""
            lower = ident.lower()
            if lower in LABEL_LIST_MODIFIERS:
                if following == "(":
                    i = consume_label_list(expr, nxt)
                elif lower in ("group_left", "group_right"):
                    pass
                else:
                    raise Unclassifiable(f"'{ident}' must be followed by a label list")
            elif lower in KEYWORDS:
                pass
            elif ident in AGGREGATIONS and re.match(r"(by|without)\s*\(", expr[nxt:], re.IGNORECASE):
                # `sum by (le) (...)`: the modifier and its label list are consumed next.
                pass
            elif following == "(":
                if ident not in FUNCTIONS and ident not in AGGREGATIONS:
                    raise Unclassifiable(f"unknown function '{ident}'")
            else:
                names.append(ident)
        elif ch == "$":
            raise Unclassifiable("template variable outside a label matcher or range selector")
        elif ch in OPERATOR_CHARS or ch == "~":
            i += 1
        else:
            raise Unclassifiable(f"unexpected character '{ch}'")
    return names


def allowed(name, exact, prefixes):
    return name in exact or any(name.startswith(prefix) for prefix in prefixes)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--print-metrics", action="store_true")
    args = parser.parse_args()

    exact, prefixes = load_allowlist(args.allowlist)
    try:
        entries = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"invalid JSON input: {exc}", file=sys.stderr)
        return 1
    if not isinstance(entries, list) or not entries:
        print("expected a non-empty JSON array of {source, expr}", file=sys.stderr)
        return 1

    failures = 0
    for entry in entries:
        source, expr = entry.get("source", "?"), entry.get("expr")
        if not isinstance(expr, str) or not expr.strip():
            print(f"FAIL {source}: empty or missing expression", file=sys.stderr)
            failures += 1
            continue
        try:
            names = metric_names(expr)
        except Unclassifiable as exc:
            print(f"FAIL {source}: cannot classify expression ({exc}): {expr.strip()}", file=sys.stderr)
            failures += 1
            continue
        for name in names:
            if args.print_metrics:
                print(f"{source}\t{name}")
            if not allowed(name, exact, prefixes):
                print(f"FAIL {source}: metric '{name}' is not on the allowlist", file=sys.stderr)
                failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
