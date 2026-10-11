"""Regression checks for process attribution in the bounded emulator runner."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "emulator_guard", Path(__file__).with_name("check-emulator.py")
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ProcessAttributionTest(unittest.TestCase):
    def test_codex_includes_cli_and_gui_paths_with_spaces(self):
        rows = [
            ["1", "0", "2048", "/Applications/ChatGPT.app/Codex (Renderer)", "gui"],
            ["2", "1", "1024", "/Applications/codex-cli/codex", "cli"],
            ["3", "0", "9999", "/bin/zsh", "echo Codex"],
        ]
        self.assertEqual(guard.codex_rss(rows), 3072)

    def test_java_path_with_spaces_detects_each_build_launcher(self):
        for marker in (
            "org.gradle.launcher.daemon.bootstrap.GradleDaemon",
            "org.gradle.launcher.GradleMain",
            "org.gradle.wrapper.GradleWrapperMain",
            "org.jetbrains.kotlin.daemon.KotlinCompileDaemon",
        ):
            with self.subTest(marker=marker):
                row = ["4", "0", "10", "/Applications/Android Studio.app/jbr/bin/java", marker]
                self.assertEqual(guard.build_pids([row]), [4])

    def test_command_text_does_not_impersonate_java(self):
        rows = [
            ["5", "0", "10", "/bin/zsh", "org.gradle.wrapper.GradleWrapperMain"],
            ["6", "0", "10", "/bin/java", "unrelated"],
        ]
        self.assertEqual(guard.build_pids(rows), [])


if __name__ == "__main__":
    unittest.main()
