import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch
import urllib.error

spec = importlib.util.spec_from_file_location("grants", Path(__file__).resolve().parents[1] / "patch-grant-types.py")
grants = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grants)


class GrantPatch(unittest.TestCase):
    def setUp(self):
        self.env = {"TF_VAR_authentik_url": "https://id.example.com", "TF_VAR_authentik_token": "test-secret-token",
                    "AUTHENTIK_PROVIDER_ID": "42", "GRANT_TYPES_JSON": '["authorization_code","refresh_token"]'}
        self.output = io.StringIO()

    def invoke(self, opener):
        with patch.object(grants.urllib.request, "build_opener", return_value=opener), contextlib.redirect_stderr(self.output), contextlib.redirect_stdout(self.output):
            result = grants.main(self.env)
        self.assertNotIn(self.env.get("TF_VAR_authentik_token", "test-secret-token"), self.output.getvalue())
        return result

    def test_environment_credentials_and_patch(self):
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value.status = 200
        self.assertEqual(self.invoke(opener), 0)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.method, "PATCH")
        self.assertEqual(request.full_url, "https://id.example.com/api/v3/providers/oauth2/42/")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-secret-token")

    def test_missing_credentials_stop_before_network(self):
        del self.env["TF_VAR_authentik_token"]
        opener = MagicMock()
        self.assertEqual(self.invoke(opener), 1)
        opener.open.assert_not_called()

    def test_reject_invalid_grants(self):
        self.env["GRANT_TYPES_JSON"] = '{}'
        opener = MagicMock()
        self.assertEqual(self.invoke(opener), 1)
        opener.open.assert_not_called()

    def test_http_error_omits_response(self):
        opener = MagicMock()
        opener.open.side_effect = urllib.error.HTTPError("https://id.example.com", 403, "private response", {}, None)
        self.assertEqual(self.invoke(opener), 1)
        self.assertNotIn("private response", self.output.getvalue())

    def test_redirects_are_not_followed(self):
        self.assertIsNone(grants.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example.com"))


if __name__ == "__main__":
    unittest.main()
