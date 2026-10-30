import importlib.util
import tempfile
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_config", ROOT / "scripts" / "render_config.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TemplateTests(unittest.TestCase):
    def test_example_env_and_render(self):
        variables = module.read_env(ROOT / ".env.example")
        with tempfile.TemporaryDirectory() as folder:
            for source, destination in module.TEMPLATES.items():
                rendered = module.render((ROOT / source).read_text(), variables)
                out = Path(folder, destination)
                out.write_text(rendered)
                self.assertNotIn("{{", rendered)
                self.assertIn("203.0.113.10", rendered) if "kamailio" in source else None

    def test_template_security(self):
        for source in module.TEMPLATES:
            text = (ROOT / source).read_text()
            # Templates must contain placeholders rather than actual network IPs;
            # localhost is allowed for RTPengine control.
            ips = re.findall(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])", text)
            self.assertTrue(all(ip == "127.0.0.1" for ip in ips),
                            f"Unexpected literal IPv4 in {source}: {ips}")
        self.assertIn('{{SIP_PUBLIC_IP}}', (ROOT / "templates/kamailio/coovox.cfg.tpl").read_text())
        self.assertIn('branch_route[PUBLIC_FORK]', (ROOT / "templates/kamailio/coovox.cfg.tpl").read_text())
        self.assertIn('regmulti=>', (ROOT / "templates/kamailio/coovox.cfg.tpl").read_text())

    def test_missing_env(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder, "missing.env")
            p.write_text("SIP_PUBLIC_IP=203.0.113.10\n")
            with self.assertRaises(ValueError):
                module.read_env(p)


if __name__ == "__main__":
    unittest.main()
