import importlib.util
import io
import unittest
from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "oauth2_config.py"
SPEC = importlib.util.spec_from_file_location("oauth2_config", MODULE_PATH)
oauth2_config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(oauth2_config)


class OAuth2ConfigurationTests(unittest.TestCase):
    def test_repository_configuration_is_valid(self):
        self.assertEqual([], oauth2_config.validate_all())

    def test_oidc_subject_must_reference_manager_token_contract(self):
        platform = oauth2_config.load_yaml(oauth2_config.PLATFORM_FILE)
        platform["spec"]["oidcPolicies"][0]["attributeContractFulfillment"]["sub"]["value"] = "Username"
        errors, _ = oauth2_config.validate_platform(platform)
        self.assertTrue(any("maps sub from unknown token attribute 'Username'" in error for error in errors))

    def test_non_deployable_example_matches_schema(self):
        example = oauth2_config.load_yaml(
            oauth2_config.ROOT / "oauth2" / "examples" / "oauth2_example_example-app.yaml"
        )
        self.assertEqual([], oauth2_config.schema_errors(example, oauth2_config.CLIENT_SCHEMA))

    def test_codeowners_is_reproducible(self):
        actual = (oauth2_config.ROOT / ".github" / "CODEOWNERS").read_text(encoding="utf-8")
        self.assertEqual(actual, oauth2_config.codeowners_content())

    def test_duplicate_yaml_keys_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate YAML key"):
            yaml.load(io.StringIO("key: one\nkey: two\n"), Loader=oauth2_config.UniqueKeyLoader)

    def test_https_redirect_is_accepted(self):
        self.assertIsNone(oauth2_config.unsafe_uri("https://app.example.com/callback", "public_spa"))

    def test_remote_http_and_wildcards_are_rejected(self):
        self.assertIsNotNone(oauth2_config.unsafe_uri("http://app.example.com/callback", "public_spa"))
        self.assertIsNotNone(oauth2_config.unsafe_uri("https://*.example.com/callback", "confidential_web"))

    def test_native_redirect_exceptions_are_narrow(self):
        self.assertIsNone(oauth2_config.unsafe_uri("http://127.0.0.1:8080/callback", "native"))
        self.assertIsNone(oauth2_config.unsafe_uri("com.example.app:/callback", "native"))

    def test_environment_overlay_preserves_profile(self):
        spec = {
            "profile": "public_spa",
            "redirectUris": ["https://base.example/callback"],
            "environments": {"development": {"redirectUris": ["https://dev.example/callback"]}},
        }
        rendered = oauth2_config.effective_spec(spec, "development")
        self.assertEqual(["https://dev.example/callback"], rendered["redirectUris"])
        self.assertEqual("public_spa", rendered["profile"])
        self.assertNotIn("environments", rendered)


if __name__ == "__main__":
    unittest.main()
