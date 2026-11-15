import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import contextlib
import io
import colors


class ColorsTest(unittest.TestCase):
    def test_path_lookup_and_rejection_without_launch(self):
        with patch('sys.argv',['colors.py','open','nectarlink-desktop']), patch('colors.shutil.which',return_value='/opt/nectarlink/nectarlink-desktop'), patch('colors.subprocess.Popen') as launch, contextlib.redirect_stdout(io.StringIO()):
            colors.main()
            self.assertEqual(launch.call_args.args[0],['/opt/nectarlink/nectarlink-desktop'])
        with patch('sys.argv',['colors.py','open','relative/app']), patch('colors.subprocess.Popen') as launch:
            with self.assertRaises(SystemExit): colors.main()
            launch.assert_not_called()
        with patch('sys.argv',['colors.py','open','nectarlink-desktop']), patch('colors.shutil.which',return_value=None), patch('colors.subprocess.Popen') as launch:
            with self.assertRaises(SystemExit): colors.main()
            launch.assert_not_called()
    def test_timeline_launch_uses_fixed_task_without_shell(self):
        with patch("sys.argv", ["colors.py", "open-timeline", "/fake/app"]), \
                patch("colors.subprocess.Popen") as launch, contextlib.redirect_stdout(io.StringIO()):
            colors.main()
        self.assertEqual(launch.call_args.args[0], ["/fake/app", "--task", "open-timeline"])
        self.assertTrue(launch.call_args.kwargs["start_new_session"])
        self.assertNotIn("shell", launch.call_args.kwargs)

    def test_switch_and_invalid_command(self):
        helper = Path(__file__).with_name("colors.py")
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            env = dict(os.environ, XDG_CONFIG_HOME=tmp)
            palette = Path(tmp) / "nectarlink/noctalia-colors.json"
            palette.parent.mkdir()
            palette.write_text('{"test":"unchanged"}')
            original = palette.read_bytes()
            def run(cmd):
                return json.loads(subprocess.check_output(["python", str(helper), cmd], env=env))
            self.assertTrue(run("status")["enabled"])
            self.assertFalse(run("disable")["enabled"])
            self.assertFalse(run("disable")["enabled"])
            self.assertTrue(run("enable")["enabled"])
            self.assertTrue(run("enable")["enabled"])
            self.assertEqual(palette.read_bytes(), original)
            self.assertNotEqual(subprocess.run(["python", str(helper), "invalid"], env=env,
                                               capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
