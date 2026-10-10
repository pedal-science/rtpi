"""piv-boot, off the board.

    python3 -m unittest discover -s tests/piv-boot -v

Each test builds a fake piv under a temporary PIVBOOT_PREFIX: a boot partition holding the one
command line piv boots (cmdline.txt), a device.env beside it, a /proc/cmdline saying what is
running now, and a reboot command that records that it was called instead of rebooting.

The case this suite exists for is the one on the bench: the card still carries the old CPU
profile (`isolcpus=managed_irq,domain,2-3`) while devices/piv/device.env and
devices/piv/etc/rtpi/audio-tune.conf have moved to 1-3.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RTPI = os.path.dirname(os.path.dirname(HERE))
PIV = os.path.join(RTPI, "devices", "piv")
PIVBOOT = os.path.join(PIV, "usr/local/sbin/piv-boot")
ENV = os.path.join(PIV, "device.env")

loader = importlib.machinery.SourceFileLoader("pivboot", PIVBOOT)
spec = importlib.util.spec_from_loader("pivboot", loader)
pb = importlib.util.module_from_spec(spec)
loader.exec_module(pb)

# What piv booted from 2026-09-29 to 2026-10-09, as devices/piv/backups/*/current-cmdline.txt
# records it: the old CPU profile in the middle of the line, which is the whole point.
OLD_TUNING = "isolcpus=managed_irq,domain,2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1"
NEW_TUNING = "isolcpus=managed_irq,domain,1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0 skew_tick=1"


def cmdline_text(tuning=OLD_TUNING, root="root=LABEL=writable", extra="", newline=False):
    """A plausible /boot/firmware/cmdline.txt: the tuning arguments in the middle of the line,
    next to the arguments that have to survive anything this tool does."""
    line = ("console=serial0,115200 console=tty1 multipath=off dwc_otg.lpm_enable=0 "
            f"{root} rootfstype=ext4 rootwait fixrtc cfg80211.ieee80211_regdom=GB "
            f"{tuning} rd.shell=0 rd.emergency=reboot rd.retry=60 rd.timeout=90 panic=10")
    if extra:
        line = f"{line} {extra}"
    return line + ("\n" if newline else "")


class FakePiv(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="pivboot-")
        self.boot = f"{self.root}/boot/firmware"
        os.makedirs(f"{self.root}/etc/rtpi")
        os.makedirs(self.boot)
        os.makedirs(f"{self.root}/run")
        os.makedirs(f"{self.root}/proc")
        shutil.copy(ENV, f"{self.root}/etc/rtpi/device.env")
        self.env_path = f"{self.root}/etc/rtpi/device.env"
        self.env = pb.read_env(ENV)
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text())
        self.boot_as(OLD_TUNING)
        self.reboots = f"{self.root}/reboots"
        with open(f"{self.root}/reboot", "w") as f:
            f.write(f'#!/bin/sh\necho called >> {self.reboots}\n')
        os.chmod(f"{self.root}/reboot", 0o755)

    def tearDown(self):
        shutil.rmtree(self.root)

    # --- the fake board
    def boot_as(self, tuning):
        with open(f"{self.root}/proc/cmdline", "w") as f:
            f.write(cmdline_text(tuning=tuning, newline=True))

    def run_pb(self, *args, check=True, env_path=None):
        e = dict(os.environ, PIVBOOT_PREFIX=self.root, PIVBOOT_NO_MOUNT="1",
                 PIVBOOT_REBOOT=f"{self.root}/reboot", TZ="UTC")
        r = subprocess.run(["python3", PIVBOOT, "--env", env_path or self.env_path, *args],
                           env=e, capture_output=True, text=True)
        if check and r.returncode:
            self.fail(f"piv-boot {' '.join(args)} failed: {r.stderr}")
        return r

    def read(self, path):
        with open(path) as f:
            return f.read()

    def card(self):
        return self.read(f"{self.boot}/cmdline.txt")

    def card_tokens(self):
        return pb.lines_of(self.card())[0]

    def backups(self):
        return sorted(f for f in os.listdir(self.boot) if f.startswith("cmdline.txt.bak-"))

    def reboots_seen(self):
        return self.read(self.reboots).split("\n")[:-1] if os.path.exists(self.reboots) else []

    def env_copy(self, **overrides):
        """A device.env of our own: this is how a board whose facts differ is simulated without
        touching the repo's copy. Pass the path to run_pb(..., env_path=...)."""
        text = self.read(self.env_path)
        for key, value in overrides.items():
            lines = [l for l in text.splitlines() if not l.startswith(f"{key}=")]
            lines.append(f'{key}="{value}"')
            text = "\n".join(lines) + "\n"
        path = f"{self.root}/etc/rtpi/device.env.test"
        with open(path, "w") as f:
            f.write(text)
        return path


class TestStatus(FakePiv):
    def test_status_shows_the_card_the_running_line_and_the_proposed_one(self):
        r = self.run_pb("status")
        self.assertIn("on card    isolcpus=managed_irq,domain,2-3", r.stdout)
        self.assertIn("running    isolcpus=managed_irq,domain,2-3", r.stdout)
        self.assertIn("proposed   ", r.stdout)
        self.assertIn("isolcpus=managed_irq,domain,1-3 nohz_full=1-3", r.stdout)
        self.assertIn("-isolcpus=managed_irq,domain,2-3", r.stdout)
        self.assertIn("+isolcpus=managed_irq,domain,1-3", r.stdout)
        self.assertIn("+skew_tick=1", r.stdout)
        self.assertIn("cmdline.txt", r.stdout)

    def test_status_says_so_when_the_running_line_already_matches(self):
        self.run_pb("set-args", "--yes")                 # the card now carries the new profile
        self.boot_as(NEW_TUNING)                         # and this boot is running it
        r = self.run_pb("status")
        self.assertIn("running    isolcpus=managed_irq,domain,1-3", r.stdout)
        self.assertNotIn("a reboot applies", r.stdout)

    def test_status_writes_nothing(self):
        before = self.card()
        os.utime(f"{self.boot}/cmdline.txt", (1000000000, 1000000000))
        self.run_pb("status")
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])
        self.assertEqual(os.path.getmtime(f"{self.boot}/cmdline.txt"), 1000000000)
        self.assertEqual(self.reboots_seen(), [])

    def test_status_survives_a_line_it_would_refuse_to_write(self):
        """A card that is already in a state this tool would not write is exactly when someone
        runs status; it has to report rather than fail."""
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text().replace(" rd.emergency=reboot", ""))
        r = self.run_pb("status")
        self.assertIn("refused", r.stdout)
        self.assertIn("rd.emergency", r.stdout)


class TestReadingDeviceEnv(FakePiv):
    def test_the_arguments_come_from_device_env(self):
        """Not from anything hard-coded here: change device.env and the proposal changes with it."""
        other = "isolcpus=managed_irq,domain,1-2 nohz_full=1-2 rcu_nocbs=1-2 irqaffinity=0 skew_tick=1"
        path = self.env_copy(AUDIO_TUNING_ARGS=other)
        before = self.card()
        r = self.run_pb("set-args", env_path=path)
        self.assertIn("+isolcpus=managed_irq,domain,1-2", r.stderr)
        self.assertIn("-isolcpus=managed_irq,domain,2-3", r.stderr)
        self.assertEqual(self.card(), before, "showing the proposal must not write it")

        self.run_pb("set-args", "--yes", env_path=path)
        self.assertIn(other, self.card())
        self.assertNotIn("isolcpus=managed_irq,domain,2-3", self.card())

    def test_the_repo_s_device_env_is_the_amended_rules(self):
        """The values the tool will write on piv, and the ones audio-tune.conf has to agree with."""
        env = pb.read_env(ENV)
        self.assertEqual(env["AUDIO_TUNING_ARGS"], NEW_TUNING)
        self.assertEqual(env["BOOT_MOUNT"], "/boot/firmware")
        conf = self.read(os.path.join(PIV, "etc/rtpi/audio-tune.conf"))
        self.assertIn('ISOLATED_CPUS="1-3"', conf)
        self.assertIn('HOUSEKEEPING_CPUS="0"', conf)
        self.assertIn('AUDIO_IRQ_CPU="1"', conf)
        for word in ("nohz_full=1-3", "rcu_nocbs=1-3", "irqaffinity=0"):
            self.assertIn(word, env["AUDIO_TUNING_ARGS"])

    def test_an_empty_profile_is_refused(self):
        path = self.env_copy(AUDIO_TUNING_ARGS="")
        r = self.run_pb("set-args", "--yes", check=False, env_path=path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("AUDIO_TUNING_ARGS is empty", r.stderr)
        self.assertIn("isolcpus=managed_irq,domain,2-3", self.card())


class TestRewriting(FakePiv):
    def test_rewrites_the_tuning_and_keeps_every_other_argument(self):
        before = self.card_tokens()
        self.run_pb("set-args", "--yes")
        after = self.card_tokens()
        keys = pb.tuning_keys(self.env)
        self.assertEqual([t for t in before if not pb.is_tuning(t, keys)],
                         [t for t in after if not pb.is_tuning(t, keys)],
                         "only the tuning arguments may change")
        self.assertEqual([t for t in after if pb.is_tuning(t, keys)], NEW_TUNING.split())
        for word in self.env["DRACUT_SAFETY_ARGS"].split() + self.env["PANIC_ARGS"].split():
            self.assertIn(word, after)
        self.assertIn("root=LABEL=writable", after)
        self.assertIn("rootfstype=ext4", after)

    def test_the_tuned_arguments_land_where_the_old_ones_were(self):
        """Appending instead would leave the old profile on the line for one of the two sets of
        keys that disagree, which is the failure this tool exists to prevent."""
        self.run_pb("set-args", "--yes")
        after = self.card_tokens()
        self.assertNotIn("isolcpus=managed_irq,domain,2-3", after)
        self.assertNotIn("irqaffinity=0-1", after)
        self.assertLess(after.index("root=LABEL=writable"), after.index("isolcpus=managed_irq,domain,1-3"))
        self.assertLess(after.index("isolcpus=managed_irq,domain,1-3"), after.index("rd.shell=0"))

    def test_appends_when_the_card_has_no_tuning_at_all(self):
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text(tuning="").replace("  ", " "))
        self.run_pb("set-args", "--yes")
        self.assertEqual(self.card_tokens()[-len(NEW_TUNING.split()):], NEW_TUNING.split())
        self.assertIn("rd.emergency=reboot", self.card())

    def test_dry_run_writes_nothing(self):
        before = self.card()
        r = self.run_pb("set-args", "--dry-run")
        self.assertIn("-isolcpus=managed_irq,domain,2-3", r.stderr)
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.reboots_seen(), [])

    def test_set_args_without_yes_writes_nothing(self):
        before = self.card()
        r = self.run_pb("set-args")
        self.assertIn("nothing written", r.stderr)
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])

    def test_it_does_not_reboot_unless_asked(self):
        self.run_pb("set-args", "--yes")
        self.assertEqual(self.reboots_seen(), [], "--yes writes; the reboot is a separate act")
        self.run_pb("set-args", "--restore", "--yes")
        self.run_pb("set-args", "--yes", "--reboot")
        self.assertEqual(self.reboots_seen(), ["called"])

    def test_a_missing_cmdline_is_not_a_piv_boot_tree(self):
        os.remove(f"{self.boot}/cmdline.txt")
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not a piv boot tree", r.stderr)

    def test_the_line_is_written_whole_or_not_at_all(self):
        """The write goes to a temporary name and is renamed over the file, so a reader never
        sees half a command line."""
        self.run_pb("set-args", "--yes")
        self.assertEqual(os.listdir(self.boot),
                         sorted(["cmdline.txt"] + self.backups()))
        self.assertNotIn("cmdline.txt.tmp", os.listdir(self.boot))

    def test_a_line_with_no_trailing_newline_stays_that_way(self):
        self.run_pb("set-args", "--yes")
        self.assertFalse(self.card().endswith("\n"))
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text(tuning=OLD_TUNING, newline=True))
        self.run_pb("set-args", "--yes")
        self.assertTrue(self.card().endswith("\n"))


class TestRefusals(FakePiv):
    def test_refuses_when_the_safety_arguments_would_be_lost(self):
        """The dracut lockout, in one test: the board's line does not have what device.env says
        every line must have, and the tool stops rather than write a line it cannot vouch for."""
        path = self.env_copy(DRACUT_SAFETY_ARGS="rd.shell=0 rd.emergency=reboot rd.retry=60 "
                                                "rd.timeout=90 rd.debug=1")
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False, env_path=path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rd.debug=1", r.stderr)
        self.assertIn("safety arguments", r.stderr)
        self.assertEqual(self.card(), before, "a refused write must change nothing")
        self.assertEqual(self.backups(), [])

    def test_refuses_when_device_env_itself_has_lost_a_safety_argument(self):
        """The safety set is required as literal keys, not read back from the same file that would
        be missing them: a device.env that dropped rd.emergency= is a refusal, not an agreement.
        The card has to be in the same state, because a safety argument already on the line is
        kept -- this is about the tool never *writing* a line without one."""
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text().replace("rd.emergency=reboot ", ""))
        path = self.env_copy(DRACUT_SAFETY_ARGS="rd.shell=0 rd.retry=60 rd.timeout=90")
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False, env_path=path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rd.emergency", r.stderr)
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])

    def test_refuses_when_the_root_selector_would_change(self):
        """Nothing in the audio profile may move where the root comes from. If it ever tried --
        an AUDIO_TUNING_ARGS line that swallowed root= -- this is the check that stops it."""
        path = self.env_copy(AUDIO_TUNING_ARGS=NEW_TUNING + " root=LABEL=somewhere-else")
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False, env_path=path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("root selector would change", r.stderr)
        self.assertIn("root=LABEL=writable", r.stderr)
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])

    def test_refuses_a_card_with_no_root(self):
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text().replace("root=LABEL=writable ", ""))
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no root=", r.stderr)

    def test_refuses_a_card_with_two_roots(self):
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text(extra="root=PARTUUID=deadbeef"))
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("more than one root", r.stderr)

    def test_the_checks_are_on_the_line_that_would_be_written(self):
        """check_line is the one gate: it can be asked directly, on tokens, with no filesystem."""
        self.assertIsNone(pb.check_line(cmdline_text().split(), self.env))
        with self.assertRaises(ValueError):
            pb.check_line(cmdline_text().replace("panic=10", "").split(), self.env)
        with self.assertRaises(ValueError):
            pb.check_line(cmdline_text().replace("rd.shell=0 ", "").split(), self.env)

    def test_a_refusal_names_what_is_missing_and_why_it_matters(self):
        with self.assertRaises(ValueError) as ctx:
            pb.check_line(cmdline_text().replace("rd.timeout=90 ", "").split(), self.env)
        self.assertIn("rd.timeout=90", str(ctx.exception))
        self.assertIn("initramfs", str(ctx.exception))


class TestBackupAndRestore(FakePiv):
    def test_the_replaced_line_is_kept_beside_it_and_restored(self):
        before = self.card()
        self.run_pb("set-args", "--yes")
        self.assertEqual(len(self.backups()), 1)
        self.assertRegex(self.backups()[0], r"^cmdline\.txt\.bak-\d{8}T\d{6}Z$")
        self.assertEqual(self.read(f"{self.boot}/{self.backups()[0]}"), before)
        self.assertIn("isolcpus=managed_irq,domain,1-3", self.card())

        self.run_pb("set-args", "--restore")
        self.assertEqual(self.card(), before, "byte for byte, including the trailing whitespace")
        self.assertEqual(self.reboots_seen(), [])

    def test_restore_without_a_backup_says_so(self):
        r = self.run_pb("set-args", "--restore", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nothing to restore", r.stderr)

    def test_restore_refuses_a_backup_that_would_move_the_root(self):
        """A backup of a different root is a root change, not a boot-argument change: it is
        refused unless the caller says --root in as many words."""
        stale = f"{self.boot}/cmdline.txt.bak-20260101T000000Z"
        with open(stale, "w") as f:
            f.write(cmdline_text(root="root=LABEL=elsewhere", newline=True))
        r = self.run_pb("set-args", "--restore", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("root selector", r.stderr)
        self.assertIn("root=LABEL=writable", self.card())

        self.run_pb("set-args", "--restore", "--root", "LABEL=elsewhere")
        self.assertIn("root=LABEL=elsewhere", self.card())

    def test_restore_refuses_a_backup_that_lost_a_safety_argument(self):
        stale = f"{self.boot}/cmdline.txt.bak-20260101T000000Z"
        with open(stale, "w") as f:
            f.write(cmdline_text().replace("rd.shell=0 ", "") + "\n")
        r = self.run_pb("set-args", "--restore", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rd.shell", r.stderr)
        self.assertIn("rd.shell=0", self.card())

    def test_restore_shows_the_change_and_dry_run_still_writes_nothing(self):
        """--restore writes without --yes, because it is the way out of a line that will not boot;
        --dry-run is how you see it first, and it is the only thing that stops it."""
        before = self.card()
        self.run_pb("set-args", "--yes")
        tuned = self.card()
        r = self.run_pb("set-args", "--restore", "--dry-run")
        self.assertIn("-isolcpus=managed_irq,domain,1-3", r.stderr)
        self.assertIn("nothing written", r.stderr)
        self.assertEqual(self.card(), tuned)
        self.run_pb("set-args", "--restore")
        self.assertEqual(self.card(), before, "the backup is back, byte for byte")


class TestIdempotence(FakePiv):
    def test_running_it_twice_changes_nothing_and_adds_no_backup(self):
        self.run_pb("set-args", "--yes")
        once, backups = self.card(), list(self.backups())
        mtime = os.path.getmtime(f"{self.boot}/cmdline.txt")
        r = self.run_pb("set-args", "--yes")
        self.assertIn("already says what device.env says", r.stderr)
        self.assertEqual(self.card(), once)
        self.assertEqual(self.backups(), backups, "no second backup for a line already in place")
        self.assertEqual(os.path.getmtime(f"{self.boot}/cmdline.txt"), mtime)
        # and the card still has exactly one copy of each argument
        self.assertEqual(self.card_tokens().count("skew_tick=1"), 1)
        self.assertEqual(self.card().count("rd.emergency=reboot"), 1)

    def test_a_second_run_does_not_duplicate_the_tuned_arguments(self):
        """Move the card back to the old profile underneath the tool, as a board that was
        rewritten by hand would be, and check the rewrite is still not additive."""
        self.run_pb("set-args", "--yes")
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text(tuning=OLD_TUNING + " skew_tick=1"))
        self.run_pb("set-args", "--yes")
        tokens = self.card_tokens()
        self.assertEqual(tokens.count("skew_tick=1"), 1)
        self.assertEqual(tokens.count("irqaffinity=0"), 1)
        self.assertEqual([t for t in tokens if pb.is_tuning(t, pb.tuning_keys(self.env))],
                         NEW_TUNING.split())

    def test_the_backup_set_stays_bounded(self):
        """set-args is meant to be run repeatedly while a profile is worked out, and piv's boot
        partition is 505M: old command lines must not accumulate, however many runs it takes."""
        for _ in range(4):
            with open(f"{self.boot}/cmdline.txt", "w") as f:
                f.write(cmdline_text(tuning="isolcpus=managed_irq,domain=2-3"))
            self.run_pb("set-args", "--yes")
            self.run_pb("set-args", "--restore", "--yes")
        self.assertLessEqual(len(self.backups()), pb.KEEP_BACKUPS)
        self.assertGreaterEqual(len(self.backups()), 1)
        self.assertIn("isolcpus=managed_irq,domain=2-3", self.card())

    def test_two_writes_in_the_same_second_do_not_overwrite_each_others_backup(self):
        """The stamp has one-second resolution, and set-args is meant to be run twice in a row
        while a profile is worked out. The second run's backup must not land on the first one's,
        or --restore would put back the line it was supposed to undo."""
        old = self.card()
        self.run_pb("set-args", "--yes")
        tuned = self.card()
        self.assertNotEqual(old, tuned)
        with open(f"{self.boot}/cmdline.txt", "w") as f:
            f.write(cmdline_text(tuning="isolcpus=managed_irq,domain=1-2"))
        second = self.card()
        self.run_pb("set-args", "--yes")                  # a second write, same second
        self.assertEqual(self.card(), tuned)
        kept = [self.read(f"{self.boot}/{b}") for b in self.backups()]
        self.assertIn(old, kept, "the line the first write replaced")
        self.assertIn(second, kept, "the line the second write replaced")
        self.assertEqual(len(set(self.backups())), len(self.backups()), "distinct names")

    def test_a_run_with_nothing_to_do_after_a_restore_is_quiet(self):
        before = self.card()
        self.run_pb("set-args", "--yes")
        self.run_pb("set-args", "--restore")
        r = self.run_pb("set-args", "--restore", "--yes")
        self.assertIn("already what", r.stderr)
        self.assertEqual(self.card(), before)


if __name__ == "__main__":
    unittest.main()
