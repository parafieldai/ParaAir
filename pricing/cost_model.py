#!/usr/bin/env python3
"""ParaAir Cloud cost and contribution model.

Stdlib only. Reads pricing/inputs.json (sourced provider rates kept separate
from labelled assumptions) and prints or writes per-scenario monthly costs and
contribution for personal and team plans.

Units: customer capacity and provider storage are decimal TB (10^12 bytes).
Rates quoted per GiB-hour, per TiB or per GB are normalized in inputs.json
before use; this module never converts units implicitly.

Usage:
  python3 -I pricing/cost_model.py                 # markdown summary
  python3 -I pricing/cost_model.py --json OUT.json # full results
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from pathlib import Path

TB = 10**12
HERE = Path(__file__).resolve().parent


def load_inputs(path: Path | None = None) -> dict:
    with open(path or HERE / "inputs.json", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Upstream cost of one account-month


def upstream_cost(provider: dict, workload: dict, a: dict) -> dict:
    """Monthly upstream cost for one account, excluding any account-wide pooling.

    workload: logical_tb (customer bytes counted against quota), read_multiple
    (monthly application reads as a multiple of logical_tb), overhead (physical
    bytes per logical byte: versions, trash, backup copies, chunk garbage).
    """
    logical = workload["logical_tb"]
    physical = logical * workload["overhead"]
    obj_tb = a["object_size_bytes"] / TB
    read_req_tb = a.get("read_request_bytes", a["object_size_bytes"]) / TB
    read_tb = logical * workload["read_multiple"] * a["read_amplification"]
    written_tb = physical * a["monthly_write_fraction"]
    gets = read_tb / read_req_tb
    puts = written_tb / obj_tb

    storage = physical * provider["storage_usd_per_tb_month"]
    egress = egress_cost(provider, read_tb, physical)
    requests = (gets * provider.get("get_usd_per_million", 0.0)
                + puts * provider.get("put_usd_per_million", 0.0)) / 1e6
    delivery = 0.0
    d = provider.get("delivery")
    if d:
        delivery = gets * (d["usd_per_million_requests"]
                           + d["cpu_ms_per_request"] * d["usd_per_million_cpu_ms"]) / 1e6
    return {
        "physical_tb": physical,
        "read_tb": read_tb,
        "gets": gets,
        "storage": storage,
        "egress": egress,
        "requests": requests,
        "delivery": delivery,
        "total": storage + egress + requests + delivery,
    }


def egress_cost(provider: dict, read_tb: float, physical_tb: float) -> float:
    e = provider["egress"]
    if e["type"] == "free":
        return 0.0
    if e["type"] == "per_tb":
        return read_tb * e["usd_per_tb"]
    if e["type"] == "multiple_of_stored":
        return max(0.0, read_tb - e["multiple"] * physical_tb) * e["overage_usd_per_tb"]
    raise ValueError(f"unknown egress type {e['type']!r}")


# ---------------------------------------------------------------------------
# Revenue-side deductions


def payment_fee(price_per_charge: float, charges_per_year: int, processor: dict) -> float:
    """Average monthly processor fee for a subscription price."""
    per_charge = price_per_charge * processor["percent"] + processor["fixed_usd"]
    return per_charge * charges_per_year / 12


def plan_month(plan: dict, billing: str, seats: int = 1, expansion_tb: float = 0.0) -> dict:
    """Monthly-equivalent revenue and the size of each charge."""
    if billing == "monthly":
        charge = plan["monthly_usd"] * seats + plan["expansion_tb_monthly_usd"] * expansion_tb
        return {"revenue": charge, "charge": charge, "charges_per_year": 12}
    charge = plan["annual_usd"] * seats + plan["expansion_tb_annual_usd"] * expansion_tb
    return {"revenue": charge / 12, "charge": charge, "charges_per_year": 1}


def account_month(provider: dict, plan: dict, workload: dict, a: dict, *,
                  billing: str = "monthly", seats: int = 1, expansion_tb: float = 0.0,
                  processor: str | None = None, subscribers: int | None = None) -> dict:
    """Contribution for one subscribing account (personal = 1 seat; team = N seats).

    workload["logical_tb"] is absolute TB for the whole account.
    """
    proc = a["payment"][processor or a["default_processor"]]
    rev = plan_month(plan, billing, seats, expansion_tb)
    up = upstream_cost(provider, workload, a)
    fee = payment_fee(rev["charge"], rev["charges_per_year"], proc)
    ops = plan["ops_usd_per_account_month"] + plan["ops_usd_per_seat_month"] * seats
    n = subscribers or a["fixed"]["subscriber_accounts"]
    fixed = a["fixed"]["usd_per_month"] / n
    cost = up["total"] + fee + ops + fixed
    return {
        "revenue": rev["revenue"],
        "upstream": up,
        "payment_fee": fee,
        "ops": ops,
        "fixed_share": fixed,
        "cost": cost,
        "contribution": rev["revenue"] - cost,
        "margin": (rev["revenue"] - cost) / rev["revenue"] if rev["revenue"] else 0.0,
    }


# ---------------------------------------------------------------------------
# Cohorts: expected value over independent utilization/read distributions,
# with optional account-wide pooling of a provider's free-egress allowance.


def cohort_month(provider: dict, plan: dict, cohort: dict, a: dict, *, capacity_tb: float,
                 overhead: float, billing: str = "monthly", seats: int = 1,
                 pooled_egress: bool = True) -> dict:
    cells = []
    for (u, pu), (r, pr) in itertools.product(cohort["utilization"].items(),
                                              cohort["read_multiple"].items()):
        w = {"logical_tb": float(u) * capacity_tb, "read_multiple": float(r), "overhead": overhead}
        cells.append((pu * pr, w, account_month(provider, plan, w, a, billing=billing, seats=seats)))
    weight = sum(p for p, _, _ in cells)
    if abs(weight - 1.0) > 1e-9:
        raise ValueError(f"cohort {cohort.get('label')} weights sum to {weight}")

    exp = lambda f: sum(p * f(r) for p, _, r in cells)
    revenue = exp(lambda r: r["revenue"])
    cost = exp(lambda r: r["cost"])
    egress = exp(lambda r: r["upstream"]["egress"])
    if pooled_egress and provider["egress"]["type"] == "multiple_of_stored":
        # Account-wide allowance: free = multiple x total physical stored.
        e = provider["egress"]
        reads = exp(lambda r: r["upstream"]["read_tb"])
        phys = exp(lambda r: r["upstream"]["physical_tb"])
        pooled = max(0.0, reads - e["multiple"] * phys) * e["overage_usd_per_tb"]
        cost += pooled - egress
        egress = pooled
    return {
        "revenue": revenue,
        "cost": cost,
        "egress": egress,
        "contribution": revenue - cost,
        "margin": (revenue - cost) / revenue if revenue else 0.0,
        "mean_logical_tb": sum(p * w["logical_tb"] for p, w, _ in cells),
    }


# ---------------------------------------------------------------------------
# Break-even helpers


def breakeven_utilization(provider: dict, plan: dict, a: dict, *, capacity_tb: float,
                          read_multiple: float, overhead: float, billing: str = "monthly",
                          seats: int = 1, target_margin: float = 0.0) -> float | None:
    """Highest utilization (0..1) at which margin >= target; None if even 0 fails."""
    def ok(u):
        w = {"logical_tb": u * capacity_tb, "read_multiple": read_multiple, "overhead": overhead}
        return account_month(provider, plan, w, a, billing=billing, seats=seats)["margin"] >= target_margin
    if not ok(0.0):
        return None
    if ok(1.0):
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(50):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if ok(mid) else (lo, mid)
    return lo


def marginal_tb(provider: dict, price_per_tb_month: float, a: dict, *, read_multiple: float,
                overhead: float, processor: str | None = None) -> float:
    """Contribution of one additional fully used TB sold at price_per_tb_month (no fixed fee)."""
    proc = a["payment"][processor or a["default_processor"]]
    up = upstream_cost(provider, {"logical_tb": 1.0, "read_multiple": read_multiple,
                                  "overhead": overhead}, a)
    return price_per_tb_month * (1 - proc["percent"]) - up["total"]


# ---------------------------------------------------------------------------
# Report


def fmt(x: float) -> str:
    return f"-${-x:,.2f}" if x < 0 else f"${x:,.2f}"


def report(inp: dict) -> tuple[str, dict]:
    a = inp["assumptions"]
    providers = {k: v for k, v in inp["providers"].items() if not k.startswith("_")}
    plans = inp["plans"]
    out: dict = {"upstream_1tb": {}, "personal_full": {}, "personal_cohorts": {},
                 "team": {}, "breakeven": {}, "marginal_tb": {}}
    lines: list[str] = []

    # 1. Upstream cost for 1 TB physical-equivalent at 1x/3x/10x reads.
    lines.append("## Upstream cost: 1 TB logical stored, overhead 1.0")
    lines.append("| Provider | 1x reads | 3x reads | 10x reads |")
    lines.append("|---|---:|---:|---:|")
    for key, p in providers.items():
        row = []
        for r in a["read_multiples"]:
            c = upstream_cost(p, {"logical_tb": 1.0, "read_multiple": r, "overhead": 1.0}, a)
            out["upstream_1tb"].setdefault(key, {})[str(r)] = c
            row.append(fmt(c["total"]))
        lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 2. Personal plan at full utilization.
    pp = plans["personal"]
    lines.append("\n## Personal 1 TB at full utilization: monthly contribution")
    hdr = [f"O={o} R={r}x" for o in a["overhead_scenarios"] for r in a["read_multiples"]]
    for billing in ("monthly", "annual"):
        lines.append(f"\n### {billing} billing")
        lines.append("| Provider | " + " | ".join(hdr) + " |")
        lines.append("|---|" + "---:|" * len(hdr))
        for key, p in providers.items():
            row = []
            for o in a["overhead_scenarios"]:
                for r in a["read_multiples"]:
                    w = {"logical_tb": 1.0, "read_multiple": r, "overhead": o}
                    res = account_month(p, pp, w, a, billing=billing)
                    out["personal_full"].setdefault(billing, {}).setdefault(key, {})[f"{o}:{r}"] = res
                    row.append(fmt(res["contribution"]))
            lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 3. Personal cohorts.
    lines.append("\n## Personal cohorts: expected monthly contribution per subscriber")
    lines.append("| Provider | " + " | ".join(
        f"{c['label']} ({b})" for c in a["cohorts"].values() for b in ("monthly", "annual")) + " |")
    lines.append("|---|" + "---:|" * (2 * len(a["cohorts"])))
    for key, p in providers.items():
        row = []
        for ck, c in a["cohorts"].items():
            for b in ("monthly", "annual"):
                res = cohort_month(p, pp, c, a, capacity_tb=pp["included_tb"],
                                   overhead=a["cohort_overhead"]["personal"], billing=b)
                out["personal_cohorts"].setdefault(key, {})[f"{ck}:{b}"] = res
                row.append(f"{fmt(res['contribution'])} ({res['margin']:.0%})")
        lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 4. Team plan: N seats, pooled capacity, full use and cohort.
    tp = plans["team"]
    lines.append("\n## Team: monthly contribution per seat")
    cols = [(n, mode) for n in a["team_sizes"] for mode in ("full", "cohort")]
    lines.append("| Provider | " + " | ".join(f"{n} seats {m}" for n, m in cols) + " |")
    lines.append("|---|" + "---:|" * len(cols))
    for key, p in providers.items():
        row = []
        for n, mode in cols:
            cap = tp["included_tb"] * n
            if mode == "full":
                w = {"logical_tb": cap, "read_multiple": a["team_full_read_multiple"],
                     "overhead": a["cohort_overhead"]["team"]}
                res = account_month(p, tp, w, a, billing="monthly", seats=n)
            else:
                res = cohort_month(p, tp, a["cohorts"][a["team_cohort"]], a, capacity_tb=cap,
                                   overhead=a["cohort_overhead"]["team"], billing="monthly", seats=n)
            out["team"].setdefault(key, {})[f"{n}:{mode}"] = res
            row.append(f"{fmt(res['contribution'] / n)} ({res['margin']:.0%})")
        lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 5. Break-even utilization for personal monthly.
    lines.append("\n## Personal monthly: highest utilization with contribution >= 0")
    lines.append("| Provider | " + " | ".join(f"R={r}x" for r in a["read_multiples"]) + " |")
    lines.append("|---|" + "---:|" * len(a["read_multiples"]))
    for key, p in providers.items():
        row = []
        for r in a["read_multiples"]:
            u = breakeven_utilization(p, pp, a, capacity_tb=pp["included_tb"], read_multiple=r,
                                      overhead=a["cohort_overhead"]["personal"])
            out["breakeven"].setdefault(key, {})[str(r)] = u
            row.append("never" if u is None else f"{u:.0%}")
        lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 6. Marginal expansion TB.
    lines.append("\n## Expansion: contribution of one more fully used TB")
    prices = {"monthly": pp["expansion_tb_monthly_usd"], "annual": pp["expansion_tb_annual_usd"] / 12}
    lines.append("| Provider | " + " | ".join(
        f"{b} {fmt(v)} R={r}x" for b, v in prices.items() for r in (1, 3)) + " |")
    lines.append("|---|" + "---:|" * 4)
    for key, p in providers.items():
        row = []
        for b, v in prices.items():
            for r in (1, 3):
                m = marginal_tb(p, v, a, read_multiple=r, overhead=a["cohort_overhead"]["personal"])
                out["marginal_tb"].setdefault(key, {})[f"{b}:{r}"] = m
                row.append(fmt(m))
        lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    # 7. Scale: fixed costs spread over different subscriber counts (general cohort, monthly).
    out["scale"] = {}
    counts = a.get("scale_subscribers", [])
    if counts:
        lines.append("\n## Scale: personal general-cohort contribution per subscriber after fixed costs")
        lines.append(f"Fixed platform cost assumption: {fmt(a['fixed']['usd_per_month'])}/month.\n")
        lines.append("| Provider | " + " | ".join(f"{n:,} subscribers" for n in counts) + " | Subscribers to cover fixed |")
        lines.append("|---|" + "---:|" * (len(counts) + 1))
        for key in a.get("scale_providers", []):
            p = providers[key]
            base = cohort_month(p, pp, a["cohorts"]["general"], a, capacity_tb=pp["included_tb"],
                                overhead=a["cohort_overhead"]["personal"])
            before_fixed = base["contribution"] + a["fixed"]["usd_per_month"] / a["fixed"]["subscriber_accounts"]
            row = [fmt(before_fixed - a["fixed"]["usd_per_month"] / n) for n in counts]
            need = a["fixed"]["usd_per_month"] / before_fixed if before_fixed > 0 else None
            out["scale"][key] = {"before_fixed": before_fixed, "subscribers_to_cover_fixed": need}
            lines.append(f"| {p['label']} | " + " | ".join(row) + f" | {'never' if need is None else f'{need:,.0f}'} |")

    # 8. Read-size sensitivity: request-priced paths at 1 TB stored, 10x reads.
    sizes = a.get("read_request_sensitivity", [])
    if sizes:
        out["read_size"] = {}
        base = a.get("read_request_bytes", a["object_size_bytes"])
        cols = [base] + list(sizes)
        lines.append("\n## Read-size sensitivity: upstream cost at 1 TB stored, 10x reads")
        lines.append("| Provider | " + " | ".join(f"{c // 1048576} MiB reads" for c in cols) + " |")
        lines.append("|---|" + "---:|" * len(cols))
        for key, p in providers.items():
            if not (p.get("delivery") or p.get("get_usd_per_million")):
                continue
            row = []
            for c in cols:
                trial = dict(a, read_request_bytes=c)
                cost = upstream_cost(p, {"logical_tb": 1.0, "read_multiple": 10, "overhead": 1.0}, trial)["total"]
                out["read_size"].setdefault(key, {})[str(c)] = cost
                row.append(fmt(cost))
            lines.append(f"| {p['label']} | " + " | ".join(row) + " |")

    return "\n".join(lines) + "\n", out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--inputs", type=Path)
    ap.add_argument("--json", type=Path, help="write full results JSON here")
    ap.add_argument("--markdown", type=Path, help="write the summary tables here")
    args = ap.parse_args(argv)
    inp = load_inputs(args.inputs)
    text, data = report(inp)
    if args.json:
        args.json.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.write_text(text, encoding="utf-8")
    if not (args.json or args.markdown):
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
