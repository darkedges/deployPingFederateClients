import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "changed.py"
SPEC = importlib.util.spec_from_file_location("changed", MODULE_PATH)
changed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(changed)


class ChangedDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        applications = self.root / "oauth2" / "applications"
        applications.mkdir(parents=True)
        for name in ("oauth2_example_one.yaml", "oauth2_example_two.yaml"):
            (applications / name).write_text("lifecycle:\n  state: active\n", encoding="utf-8")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def classify(self, lines, **kwargs):
        return changed.classify_changes(lines, "base", root=self.root, **kwargs)

    def test_irrelevant_change_selects_no_infrastructure(self):
        result = self.classify(["M\toauth2/tools/oauth2_config.py"])
        self.assertEqual({"applications": [], "platform_changed": False}, result)

    def test_single_application_change_selects_only_that_application(self):
        target = "oauth2/applications/oauth2_example_one.yaml"
        result = self.classify([f"M\t{target}"])
        self.assertEqual([{"target": target, "action": "upsert"}], result["applications"])
        self.assertFalse(result["platform_changed"])

    def test_platform_change_does_not_select_applications(self):
        result = self.classify(["M\toauth2/platform/oauth2_platform.yaml"])
        self.assertEqual([], result["applications"])
        self.assertTrue(result["platform_changed"])

    def test_application_module_change_selects_every_application(self):
        result = self.classify(["M\tterraform/modules/oauth2-application/main.tf"])
        self.assertEqual(2, len(result["applications"]))
        self.assertFalse(result["platform_changed"])

    def test_terraform_test_change_selects_no_infrastructure(self):
        result = self.classify(["M\tterraform/stacks/application/tests/example.tftest.hcl"])
        self.assertEqual({"applications": [], "platform_changed": False}, result)

    def test_initial_push_selects_platform_and_every_application(self):
        result = self.classify([], initial=True)
        self.assertEqual(2, len(result["applications"]))
        self.assertTrue(result["platform_changed"])

    def test_disabled_deletion_selects_only_deleted_application(self):
        target = "oauth2/applications/oauth2_example_one.yaml"
        previous = "lifecycle:\n  state: disabled\n"
        result = self.classify([f"D\t{target}"], load_previous=lambda _: previous)
        self.assertEqual(
            [{"target": "deleted:example:one", "action": "delete"}],
            result["applications"],
        )

    def test_enabled_deletion_is_rejected(self):
        target = "oauth2/applications/oauth2_example_one.yaml"
        previous = "lifecycle:\n  state: active\n"
        with self.assertRaisesRegex(SystemExit, "must be disabled"):
            self.classify([f"D\t{target}"], load_previous=lambda _: previous)


if __name__ == "__main__":
    unittest.main()
