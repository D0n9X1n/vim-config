#!/usr/bin/env python3
"""Run install.sh in a disposable HOME with a stub vim (no network)."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GIT_ENV = dict(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


class Install(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="vim-install-test-")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.checkout = self.tmp / "checkout"
        tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).decode().split("\0")
        for name in filter(None, tracked):
            source = ROOT / name
            if source.is_file():
                target = self.checkout / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        self.bundle = self.checkout / "bundle"
        self.bundle.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for command in ("dirname", "date", "mv", "unlink", "ln", "touch", "pwd", "git",
                        "find", "sed", "cat", "mktemp", "rm", "head", "grep", "sort", "tr"):
            location = shutil.which(command)
            if location:
                (self.bin / command).symlink_to(location)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin), **GIT_ENV)
        for name in ("BASH_ENV", "ENV", "VIMINIT", "MYVIMRC"):
            self.env.pop(name, None)
        self.upstream = self.upstream_repo()

    def upstream_repo(self):
        seed = self.tmp / "seed"
        env = dict(os.environ, **GIT_ENV)
        subprocess.run(["git", "init", "-q", "-b", "main", str(seed)], check=True, env=env)
        (seed / "README").write_text("x\n")
        subprocess.run(["git", "-C", str(seed), "add", "README"], check=True, env=env)
        subprocess.run(["git", "-C", str(seed), "commit", "-q", "-m", "seed"], check=True, env=env)
        upstream = self.tmp / "upstream.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(upstream)], check=True, env=env)
        return upstream

    def clone(self, name):
        subprocess.run(["git", "clone", "-q", str(self.upstream), str(self.bundle / name)],
                       check=True, capture_output=True, env=dict(os.environ, **GIT_ENV))
        return self.bundle / name

    def vim_stub(self, declared=("apollo-theme",)):
        """A stub vim: PlugInstall is logged; the plugin query writes `declared`."""
        log = self.tmp / "vim-calls"
        names = " ".join(repr(d) for d in declared)
        (self.bin / "vim").write_text(f"""#!/bin/bash
printf '%s\\n' "$*" >> "{log}"
for a in "$@"; do case "$a" in */init.vim) cat "$a" >> "{self.tmp}/init-seen" ;; esac; done
case "$*" in
  *--version*) printf 'VIM - Vi IMproved 9.2\\n' ;;
  *VIM_PRUNE_DECLARED*|*writefile*) [ -n "$VIM_PRUNE_DECLARED" ] && printf '%s\\n' {names} > "$VIM_PRUNE_DECLARED" ;;
esac
exit 0
""")
        (self.bin / "vim").chmod(0o755)
        return log

    def install(self):
        result = subprocess.run(["/bin/bash", str(self.checkout / "install.sh")], env=self.env,
                                cwd=self.tmp, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_links_config(self):
        self.vim_stub()
        self.install()
        self.assertEqual((self.home / ".vim").resolve(), self.checkout.resolve())
        self.assertTrue((self.home / ".vimrc").is_symlink())

    def test_installs_plugins_and_prunes_unused(self):
        log = self.vim_stub()
        self.clone("apollo-theme")
        self.clone("vim-apollo-theme")
        result = self.install()
        self.assertIn("PlugInstall", log.read_text())
        self.assertTrue((self.bundle / "apollo-theme").is_dir())
        self.assertFalse((self.bundle / "vim-apollo-theme").exists(), result.stdout + result.stderr)
        self.assertIn("vim-apollo-theme", result.stdout)

    def test_keeps_unused_plugin_with_local_work(self):
        self.vim_stub()
        dirty = self.clone("old-plugin")
        (dirty / "mine.vim").write_text("\" mine\n")
        result = self.install()
        self.assertTrue((dirty / "mine.vim").exists())
        self.assertIn("old-plugin", result.stdout)

    def test_init_loads_private_plugins(self):
        """The plugin query must see ~/.vimrc.private, or its plugins look unused."""
        self.vim_stub()
        self.install()
        text = (self.tmp / "init-seen").read_text()
        self.assertIn(".vimrc.private", text)

    def test_failed_plugin_query_prunes_nothing(self):
        self.vim_stub(declared=())
        stale = self.clone("old-plugin")
        self.install()
        self.assertTrue(stale.is_dir())

    def test_without_vim_only_links(self):
        stale = self.clone("old-plugin")
        result = self.install()
        self.assertTrue(stale.is_dir())
        self.assertIn("PlugInstall", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
