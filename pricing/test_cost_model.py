"""Hand-checked examples for pricing/cost_model.py.

Run: python3 -I -m unittest discover -s pricing -p 'test_*.py'
"""

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cost_model as cm  # noqa: E402

MiB4 = 4 * 1024 * 1024

A = {
    "object_size_bytes": MiB4,
    "read_amplification": 1.10,
    "monthly_write_fraction": 0.15,
    "default_processor": "mor",
    "payment": {"mor": {"percent": 0.05, "fixed_usd": 0.50}},
    "fixed": {"usd_per_month": 750, "subscriber_accounts": 1000},
}
R2 = {"label": "r2", "storage_usd_per_tb_month": 15.0, "egress": {"type": "free"},
      "get_usd_per_million": 0.36, "put_usd_per_million": 4.50}
B2 = {"label": "b2", "storage_usd_per_tb_month": 6.95,
      "egress": {"type": "multiple_of_stored", "multiple": 3, "overage_usd_per_tb": 10.0}}
PERSONAL = {"included_tb": 1, "monthly_usd": 12.0, "annual_usd": 120.0,
            "expansion_tb_monthly_usd": 10.0, "expansion_tb_annual_usd": 120.0,
            "ops_usd_per_account_month": 0.60, "ops_usd_per_seat_month": 0.0}


class UpstreamTests(unittest.TestCase):
    def test_r2_one_tb_one_read(self):
        c = cm.upstream_cost(R2, {"logical_tb": 1.0, "read_multiple": 1, "overhead": 1.0}, A)
        # 1.1e12 / 4 MiB = 262,260.44 GETs at $0.36/M; 0.15e12 / 4 MiB = 35,762.79 PUTs at $4.50/M.
        self.assertAlmostEqual(c["gets"], 262_260.44, places=1)
        self.assertAlmostEqual(c["requests"], 0.094414 + 0.160933, places=5)
        self.assertAlmostEqual(c["total"], 15.255347, places=5)

    def test_b2_overage_beyond_three_times_physical(self):
        c = cm.upstream_cost(B2, {"logical_tb": 1.0, "read_multiple": 10, "overhead": 1.0}, A)
        # 11 TB read - 3 TB free = 8 TB x $10.
        self.assertAlmostEqual(c["egress"], 80.0)
        self.assertAlmostEqual(c["total"], 86.95)

    def test_b2_overhead_raises_free_allowance(self):
        c = cm.upstream_cost(B2, {"logical_tb": 1.0, "read_multiple": 3, "overhead": 1.15}, A)
        # 3.3 TB read <= 3 x 1.15 TB physical, so no overage.
        self.assertEqual(c["egress"], 0.0)

    def test_read_request_size_scales_gets_not_puts(self):
        a = dict(A, read_request_bytes=MiB4 // 4)
        c = cm.upstream_cost(R2, {"logical_tb": 1.0, "read_multiple": 1, "overhead": 1.0}, a)
        # 1.1e12 / 1 MiB = 1,049,041.75 GETs; PUTs still use 4 MiB objects.
        self.assertAlmostEqual(c["gets"], 1_049_041.75, places=1)
        self.assertAlmostEqual(c["requests"], 1_049_041.75 * 0.36 / 1e6 + 0.160933, places=5)

    def test_per_tb_egress(self):
        p = {"label": "x", "storage_usd_per_tb_month": 0.0, "egress": {"type": "per_tb", "usd_per_tb": 90.0}}
        c = cm.upstream_cost(p, {"logical_tb": 2.0, "read_multiple": 1, "overhead": 1.0}, A)
        self.assertAlmostEqual(c["egress"], 2.2 * 90.0)


class AccountTests(unittest.TestCase):
    def test_payment_fee_monthly_and_annual(self):
        self.assertAlmostEqual(cm.payment_fee(12.0, 12, A["payment"]["mor"]), 1.10)
        self.assertAlmostEqual(cm.payment_fee(120.0, 1, A["payment"]["mor"]), 6.50 / 12)

    def test_personal_full_use_contribution(self):
        free = {"label": "f", "storage_usd_per_tb_month": 7.5534, "egress": {"type": "free"}}
        r = cm.account_month(free, PERSONAL, {"logical_tb": 1.0, "read_multiple": 3, "overhead": 1.0}, A)
        # 12 - 7.5534 storage - 1.10 fee - 0.60 ops - 0.75 fixed share.
        self.assertAlmostEqual(r["contribution"], 1.9966, places=4)

    def test_team_seats_scale_revenue_and_ops(self):
        team = dict(PERSONAL, monthly_usd=24.0, ops_usd_per_account_month=1.5, ops_usd_per_seat_month=0.75)
        free = {"label": "f", "storage_usd_per_tb_month": 0.0, "egress": {"type": "free"}}
        r = cm.account_month(free, team, {"logical_tb": 0.0, "read_multiple": 1, "overhead": 1.0}, A, seats=3)
        self.assertAlmostEqual(r["revenue"], 72.0)
        self.assertAlmostEqual(r["ops"], 1.5 + 2.25)
        self.assertAlmostEqual(r["payment_fee"], 72 * 0.05 + 0.5)

    def test_breakeven_r2_matches_closed_form(self):
        a = copy.deepcopy(A)
        a["monthly_write_fraction"] = 0.0
        r2 = dict(R2, get_usd_per_million=0.0)
        u = cm.breakeven_utilization(r2, PERSONAL, a, capacity_tb=1, read_multiple=1, overhead=1.0)
        # 12 - 1.10 - 0.60 - 0.75 = 9.55 available; 9.55 / 15 = 63.67%.
        self.assertAlmostEqual(u, 9.55 / 15, places=6)


class CohortTests(unittest.TestCase):
    def test_pooled_egress_lets_light_readers_cover_heavy(self):
        cohort = {"label": "c", "utilization": {"1.0": 1.0}, "read_multiple": {"1": 0.5, "10": 0.5}}
        pooled = cm.cohort_month(B2, PERSONAL, cohort, A, capacity_tb=1, overhead=1.0, pooled_egress=True)
        single = cm.cohort_month(B2, PERSONAL, cohort, A, capacity_tb=1, overhead=1.0, pooled_egress=False)
        # Mean reads 6.05 TB vs 3 TB free: pooled overage 3.05 TB; unpooled 0.5 x 8 TB.
        self.assertAlmostEqual(pooled["egress"], 30.5)
        self.assertAlmostEqual(single["egress"], 40.0)

    def test_inputs_file_runs(self):
        inp = cm.load_inputs()
        for c in inp["assumptions"]["cohorts"].values():
            self.assertAlmostEqual(sum(c["utilization"].values()), 1.0)
            self.assertAlmostEqual(sum(c["read_multiple"].values()), 1.0)
        text, data = cm.report(inp)
        self.assertIn("Personal cohorts", text)
        self.assertTrue(data["personal_cohorts"])


if __name__ == "__main__":
    unittest.main()
