#!/usr/bin/env python3
"""Run install.sh's real plugin query with real Vim on fixture declarations."""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VIM = next((p for p in ("/opt/homebrew/bin/vim", "/usr/local/bin/vim", "/usr/bin/vim")
            if Path(p).exists()), None)


def install_text():
    return (ROOT / "install.sh").read_text()


def init_vim():
    match = re.search(r"<<'VIM'\n(.*?)\nVIM\n", install_text(), re.S)
    assert match, "install.sh has no init heredoc"
    return match.group(1)


def query_args():
    match = re.search(r'"\$VIM_BIN" -N -u "\$PRUNE_DIR/init.vim" -i NONE -es \\\n\s*(-c .*?)\s*</dev/null',
                      install_text(), re.S)
    assert match, "install.sh has no plugin query"
    return match.group(1).replace("\\\n", " ")


@unittest.skipUnless(VIM, "needs real Vim")
class PluginQuery(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="vim-query-test-")
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        vim_dir = self.home / ".vim"
        (vim_dir / "autoload").mkdir(parents=True)
        shutil.copy2(ROOT / "autoload/plug.vim", vim_dir / "autoload/plug.vim")
        self.init = self.home / "init.vim"
        self.init.write_text(init_vim())
        self.out = self.home / "declared"

    def query(self, bundles, private=None):
        (self.home / ".vimrc.bundles").write_text(bundles)
        if private is not None:
            (self.home / ".vimrc.private").write_text(private)
        env = dict(os.environ, HOME=str(self.home), VIM_PRUNE_DECLARED=str(self.out))
        cmd = f'"{VIM}" -N -u "{self.init}" -i NONE -es {query_args()} </dev/null'
        subprocess.run(["/bin/bash", "-c", cmd], env=env, cwd=self.home,
                       capture_output=True, text=True, timeout=60)
        return self.out.read_text().split() if self.out.exists() else None

    def test_lists_public_and_private_plugins(self):
        declared = self.query("Plug 'owner/public'\n", private="Plug 'owner/private'\n")
        self.assertEqual(sorted(declared), ["private", "public"])

    def test_renamed_and_custom_dirs_are_listed(self):
        declared = self.query("Plug 'owner/x', { 'as': 'renamed' }\n")
        self.assertIn("renamed", declared)

    def test_private_error_writes_no_list(self):
        declared = self.query("Plug 'owner/public'\n",
                              private="throw 'failed'\nPlug 'owner/private'\n")
        self.assertIsNone(declared)

    def test_bundles_error_writes_no_list(self):
        declared = self.query("Plug 'owner/public'\ncall NoSuchFunction()\n")
        self.assertIsNone(declared)


if __name__ == "__main__":
    unittest.main(verbosity=2)
