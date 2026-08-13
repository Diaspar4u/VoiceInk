import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ForkReleaseConfigurationTests(unittest.TestCase):
    def test_info_plist_uses_fork_release_settings(self):
        with (ROOT / "VoiceInk" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["SUFeedURL"], "$(VOICEINK_FEED_URL)")
        self.assertEqual(info["SUPublicEDKey"], "$(VOICEINK_SPARKLE_PUBLIC_KEY)")
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertNotIn("SUEnableInstallerLauncherService", info)

    def test_fork_release_config_preserves_ads_behavior_and_enables_updates(self):
        config = (ROOT / "ForkRelease.xcconfig").read_text()

        self.assertIn("LOCAL_BUILD", config)
        self.assertNotIn("FORK_DISTRIBUTION", config)
        self.assertIn("MARKETING_VERSION = 2.11+ads", config)
        self.assertIn("CURRENT_PROJECT_VERSION = 213", config)
        self.assertIn("DEVELOPMENT_TEAM = EVBK3FN863", config)
        self.assertIn("Apple Development: ANDREY SHRAYEV (87R47LZ5EP)", config)
        self.assertNotIn("Developer ID Application", config)
        self.assertNotIn("SPARKLE_PUBLIC_KEY_NOT_CONFIGURED", config)
        self.assertRegex(
            config,
            r"VOICEINK_SPARKLE_PUBLIC_KEY = [A-Za-z0-9+/]{43}=",
        )
        self.assertIn("raw.githubusercontent.com/Diaspar4u/VoiceInk/andrey/all-fixes/appcast.xml", config)
        self.assertIn("https:/$()/raw.githubusercontent.com", config)

    def test_local_behavior_no_longer_disables_fork_updates(self):
        updater = (ROOT / "VoiceInk" / "Services" / "UpdaterViewModel.swift").read_text()
        menu = (ROOT / "VoiceInk" / "Views" / "MenuBarView.swift").read_text()
        settings = (ROOT / "VoiceInk" / "Views" / "Settings" / "SettingsView.swift").read_text()

        self.assertNotIn("#if LOCAL_BUILD", updater)
        self.assertNotIn("#if !LOCAL_BUILD", menu)
        self.assertNotIn("#if !LOCAL_BUILD", settings)
        self.assertNotIn("FORK_DISTRIBUTION", updater + menu + settings)

    def test_release_script_targets_our_github_release_channel(self):
        script = (ROOT / "scripts" / "release.sh").read_text()

        self.assertIn("Apple Development: ANDREY SHRAYEV (87R47LZ5EP)", script)
        self.assertNotIn("Developer ID Application: ANDREY SHRAYEV", script)
        self.assertIn("VoiceInk ADS", script)
        self.assertIn("Diaspar4u/VoiceInk", script)
        self.assertIn("github.com/$REPOSITORY/releases/download", script)
        self.assertIn("raw.githubusercontent.com/$REPOSITORY/$FEED_BRANCH/appcast.xml", script)
        self.assertIn("-xcconfig", script)
        self.assertIn("ForkRelease.xcconfig", script)
        self.assertIn("ditto -c -k --sequesterRsrc --keepParent", script)
        self.assertIn("--publish", script)
        self.assertIn("merge-base --is-ancestor", script)
        self.assertIn("gh release create", script)
        self.assertIn("git -C \"$REPO_ROOT\" push origin", script)
        self.assertIn("curl --fail --location", script)

    def test_bridge_release_notes_exist(self):
        notes = ROOT / "release-notes" / "2.11+ads.html"
        self.assertTrue(notes.is_file())
        self.assertIn("automatic updates", notes.read_text().lower())


if __name__ == "__main__":
    unittest.main()
