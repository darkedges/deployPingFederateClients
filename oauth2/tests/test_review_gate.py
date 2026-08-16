import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "review_gate.py"
SPEC = importlib.util.spec_from_file_location("review_gate", MODULE_PATH)
review_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review_gate)


class ReviewGateTests(unittest.TestCase):
    def test_one_approval_satisfies_shared_platform_owner_team(self):
        error = review_gate.approval_error(
            {"petersmithzkp"},
            "DarkEdgesAU/identity-platform",
            {"darkedges", "petersmithzkp"},
            {"DarkEdgesAU/identity-platform": {"darkedges", "petersmithzkp"}},
        )
        self.assertIsNone(error)

    def test_distinct_teams_still_require_distinct_approvers(self):
        error = review_gate.approval_error(
            {"petersmithzkp"},
            "DarkEdgesAU/identity-platform",
            {"petersmithzkp"},
            {"DarkEdgesAU/application-owners": {"petersmithzkp"}},
        )
        self.assertEqual(
            "DarkEdgesAU/application-owners and identity-platform approvals must come from different people",
            error,
        )

    def test_identity_approval_is_always_required(self):
        error = review_gate.approval_error(
            {"application-owner"},
            "DarkEdgesAU/identity-platform",
            {"petersmithzkp"},
            {"DarkEdgesAU/application-owners": {"application-owner"}},
        )
        self.assertEqual("A current-commit identity-platform approval is required", error)


if __name__ == "__main__":
    unittest.main()
