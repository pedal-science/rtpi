"""piv-boot, off the board.

    python3 -m unittest discover -s tests/piv-boot -v

Each test builds a fake piv under a temporary PIVBOOT_PREFIX: a boot partition holding the
config.txt piv's card carries and, under the os_prefix it names for a normal boot (`current/`),
the one command line that boot tree boots; a device.env beside it, a /proc/cmdline saying what is
running now, and a reboot command that records that it was called instead of rebooting.

That layout is the point of half this suite. The firmware reads
`<BOOT_MOUNT>/<os_prefix>cmdline.txt` -- `/boot/firmware/current/cmdline.txt` on piv -- and a
`cmdline.txt` in the root of the boot partition is a leftover nothing reads. `self.card()` is the
file the firmware reads; `self.root_cmdline()` is the leftover, kept so the tests can prove the
tool does not go back to it.

The case this suite exists for is the one on the bench: the card still carries the old CPU
profile (`isolcpus=managed_irq,domain,2-3`) while devices/piv/device.env and
devices/piv/etc/rtpi/audio-tune.conf have moved to 1-3.
"""
import glob
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

# piv's boot partition, as devices/piv/backups/*/config.txt records it: the [all] at the head
# names the tree a normal boot reads, and the [tryboot] between the two [all]s names the candidate
# the one-shot flag selects. The second [all] resets that filter, which is why the firmware does
# not read new/ on an ordinary boot.
CARD_CONFIG = """[all]
os_prefix=current/

[tryboot]
os_prefix=new/

[all]
arm_64bit=1
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd.img followkernel
"""

# The root of the boot partition on a card that predates the slots (or has never been staged).
ROOT_CONFIG = """[all]
arm_64bit=1
kernel=vmlinuz
cmdline=cmdline.txt
"""

# What piv's /boot/firmware/cmdline.txt holds today: a leftover from before the slots, one
# option long, which the firmware has not read since os_prefix arrived and piv-boot used to
# rewrite. It is here so a test can prove the tool no longer touches it.
ROOT_LEFTOVER = "video=HDMI-A-1:1920x1080@60D"


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
        self.live = f"{self.boot}/current"
        os.makedirs(f"{self.root}/etc/rtpi")
        os.makedirs(self.live)
        os.makedirs(f"{self.root}/run")
        os.makedirs(f"{self.root}/proc")
        shutil.copy(ENV, f"{self.root}/etc/rtpi/device.env")
        self.env_path = f"{self.root}/etc/rtpi/device.env"
        self.env = pb.read_env(ENV)
        self.write_config(CARD_CONFIG)
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text())
        with open(self.root_cmdline(), "w") as f:
            f.write(ROOT_LEFTOVER)
        self.boot_as(OLD_TUNING)
        self.reboots = f"{self.root}/reboots"
        with open(f"{self.root}/reboot", "w") as f:
            f.write(f'#!/bin/sh\necho called >> {self.reboots}\n')
        os.chmod(f"{self.root}/reboot", 0o755)

    def tearDown(self):
        shutil.rmtree(self.root)

    # --- the fake board
    def write_config(self, text):
        with open(f"{self.boot}/config.txt", "w") as f:
            f.write(text)

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

    def said(self, r):
        """Everything the run said, wherever it said it."""
        return r.stdout + r.stderr

    def write_card(self, text):
        with open(self.card_path(), "w") as f:
            f.write(text)

    def write_card_args(self, *args, **kw):
        """set-args as an operator who means it.

        Every write whose tuning arguments are not the ones `/proc/cmdline` is running has to
        carry --write-active-line, and in this fake board that is the ordinary case: the card and
        the running line carry the old profile while device.env has moved to the new one. The
        cases that are about the gate itself call run_pb() directly, so that this helper is never
        standing in for the thing they check.
        """
        return self.run_pb("set-args", "--write-active-line", *args, **kw)

    def card_path(self):
        """The file the firmware reads: <BOOT_MOUNT>/<os_prefix>cmdline.txt."""
        return f"{self.live}/cmdline.txt"

    def root_cmdline(self):
        """The stale /boot/firmware/cmdline.txt piv really carries, which nothing reads."""
        return f"{self.boot}/cmdline.txt"

    def card(self):
        return self.read(self.card_path())

    def card_tokens(self):
        return pb.lines_of(self.card())[0]

    def backups(self):
        """The backups of the live command line: none, when the tree itself is not there."""
        if not os.path.isdir(self.live):
            return []
        return sorted(f for f in os.listdir(self.live) if f.startswith("cmdline.txt.bak-"))

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
        self.write_card_args("--yes")                    # the card now carries the new profile
        self.boot_as(NEW_TUNING)                         # and this boot is running it
        r = self.run_pb("status")
        self.assertIn("running    isolcpus=managed_irq,domain,1-3", r.stdout)
        self.assertNotIn("a reboot applies", r.stdout)

    def test_status_writes_nothing(self):
        before = self.card()
        os.utime(self.card_path(), (1000000000, 1000000000))
        self.run_pb("status")
        self.assertEqual(self.card(), before)
        self.assertEqual(self.backups(), [])
        self.assertEqual(os.path.getmtime(self.card_path()), 1000000000)
        self.assertEqual(self.reboots_seen(), [])

    def test_status_survives_a_line_it_would_refuse_to_write(self):
        """A card that is already in a state this tool would not write is exactly when someone
        runs status; it has to report rather than fail."""
        with open(self.card_path(), "w") as f:
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

        self.write_card_args("--yes", env_path=path)
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
        self.write_card_args("--yes")
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
        self.write_card_args("--yes")
        after = self.card_tokens()
        self.assertNotIn("isolcpus=managed_irq,domain,2-3", after)
        self.assertNotIn("irqaffinity=0-1", after)
        self.assertLess(after.index("root=LABEL=writable"), after.index("isolcpus=managed_irq,domain,1-3"))
        self.assertLess(after.index("isolcpus=managed_irq,domain,1-3"), after.index("rd.shell=0"))

    def test_appends_when_the_card_has_no_tuning_at_all(self):
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text(tuning="").replace("  ", " "))
        self.write_card_args("--yes")
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
        self.write_card_args("--yes")
        self.assertEqual(self.reboots_seen(), [], "--yes writes; the reboot is a separate act")
        self.run_pb("set-args", "--restore", "--yes")
        self.write_card_args("--yes", "--reboot")
        self.assertEqual(self.reboots_seen(), ["called"])

    def test_a_missing_cmdline_is_not_a_piv_boot_tree(self):
        os.remove(self.card_path())
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("does not exist", r.stderr)
        self.assertIn(f"{self.live}/cmdline.txt", r.stderr,
                      "the refusal has to say which path it looked for")

    def test_the_line_is_written_whole_or_not_at_all(self):
        """The write goes to a temporary name and is renamed over the file, so a reader never
        sees half a command line. It happens inside the tree os_prefix names, beside the
        backups, and never in the root of the boot partition."""
        self.write_card_args("--yes")
        self.assertEqual(os.listdir(self.live),
                         sorted(["cmdline.txt"] + self.backups()))
        self.assertNotIn("cmdline.txt.tmp", os.listdir(self.live))
        self.assertEqual(os.listdir(self.boot), sorted(["cmdline.txt", "config.txt", "current"]))
        self.assertEqual(self.read(self.root_cmdline()), ROOT_LEFTOVER,
                         "the leftover at the root of the boot partition is never written")

    def test_a_line_with_no_trailing_newline_stays_that_way(self):
        self.write_card_args("--yes")
        self.assertFalse(self.card().endswith("\n"))
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text(tuning=OLD_TUNING, newline=True))
        self.write_card_args("--yes")
        self.assertTrue(self.card().endswith("\n"))


class TestWritingALineThisBootHasNotRun(FakePiv):
    """`--yes` writes a line whose tuning arguments the running kernel already has, and refuses one
    it has not run: that is the write that moves what the next boot is told, in place, with no
    candidate behind it.

    The evidence is /proc/cmdline and nothing else, which is what these cases arrange. setUp runs
    the old profile while device.env has moved to the new one, so plain `--yes` is the refusal here
    and --write-active-line is the act.
    """

    def test_refused_without_the_flag_when_the_tuning_differs(self):
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.card(), before, "a refusal writes nothing at all")
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.reboots_seen(), [])

    def test_the_refusal_says_what_would_happen_and_both_ways_on(self):
        r = self.run_pb("set-args", "--yes", check=False)
        said = self.said(r)
        self.assertIn("--write-active-line", said, "the flag that means it anyway")
        self.assertIn("make piv-audio-boot-args", said, "and the route with a fallback behind it")
        self.assertIn("NEXT boot", said, "an active line applies at the next boot, in place")
        self.assertIn("no candidate", said)
        self.assertIn(OLD_TUNING, said, "what this boot is running")
        self.assertIn(NEW_TUNING, said, "and what would be written")

    def test_accepted_with_the_flag(self):
        self.run_pb("set-args", "--yes", "--write-active-line")
        self.assertIn(NEW_TUNING, self.card())
        self.assertEqual(len(self.backups()), 1, "and it is still a normal, backed-up write")

    def test_accepted_without_the_flag_when_the_line_is_the_one_running(self):
        """The gate is about isolation, not about diffing: this card has lost its tuning while the
        kernel is running device.env's, so putting it back writes a line this boot has booted and
        `--yes` alone still does it."""
        self.boot_as(NEW_TUNING)
        self.write_card(cmdline_text(tuning="").replace("  ", " "))
        r = self.run_pb("set-args", "--yes")
        self.assertIn(NEW_TUNING, self.card())
        self.assertNotIn("--write-active-line", self.said(r))

    def test_a_running_line_that_cannot_be_read_is_not_a_matching_one(self):
        """Absence of evidence, not an empty line: the one file that says whether a line has ever
        been booted is not there, so the write takes the flag -- and the refusal names the file."""
        os.remove(f"{self.root}/proc/cmdline")
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("proc/cmdline", r.stderr)
        self.assertIn("cannot be read", r.stderr)
        self.assertIn("--write-active-line", r.stderr)
        self.assertEqual(self.card(), before)
        self.run_pb("set-args", "--yes", "--write-active-line")
        self.assertIn(NEW_TUNING, self.card(), "the flag is a decision, not a dead end")

    def test_an_empty_running_line_is_the_same_absence_of_proof(self):
        open(f"{self.root}/proc/cmdline", "w").close()
        before = self.card()
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is empty", r.stderr)
        self.assertEqual(self.card(), before)

    def test_the_preview_and_the_dry_run_still_work_without_the_flag(self):
        """--dry-run writes nothing and neither does a bare set-args, so both keep working; both
        also say which flag a write would take, so the gate is not a surprise at --yes. The flag
        on its own is not a write either: --write-active-line says which line is meant, and --yes
        is still what writes."""
        before = self.card()
        for args in (("--dry-run",), (), ("--write-active-line",)):
            r = self.run_pb("set-args", *args)
            self.assertEqual(r.returncode, 0)
            self.assertIn("nothing written", r.stderr)
            if "--write-active-line" not in args:
                self.assertIn("--write-active-line", r.stderr)
            self.assertEqual(self.card(), before)
            self.assertEqual(self.backups(), [])


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
        with open(self.card_path(), "w") as f:
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
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text().replace("root=LABEL=writable ", ""))
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no root=", r.stderr)

    def test_refuses_a_card_with_two_roots(self):
        with open(self.card_path(), "w") as f:
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


class TestWhichCommandLineTheFirmwareReads(FakePiv):
    """`os_prefix` decides, not the filename. The firmware reads
    `<BOOT_MOUNT>/<os_prefix>cmdline.txt` on a normal boot, and piv's real card puts the live line
    in `current/` while a leftover `cmdline.txt` sits at the root of the boot partition. Reading
    the leftover is the fault this class exists for: it made `set-args` describe a file nobody
    boots, and refuse a write nobody was making."""

    def test_the_card_resolves_to_the_current_tree_and_writes_it(self):
        r = self.run_pb("status")
        self.assertIn(f"cmdline    {self.live}/cmdline.txt", r.stdout)

        before_root = self.read(self.root_cmdline())
        self.write_card_args("--yes")
        self.assertIn(NEW_TUNING, self.card())
        self.assertNotIn("isolcpus=managed_irq,domain,2-3", self.card())
        self.assertEqual(os.listdir(self.live), sorted(["cmdline.txt"] + self.backups()),
                         "the backup lands beside the file that was written")
        self.assertEqual(self.read(self.root_cmdline()), before_root,
                         "the leftover at the root is not the file the firmware reads")

    def test_the_tryboot_prefix_is_not_the_active_one(self):
        """`[tryboot] os_prefix=new/` describes the candidate the one-shot flag selects, and the
        `[all]` under it resets that filter. Taking the tryboot one would edit the candidate
        arm-try-piv.sh stages, with `current/` still what boots."""
        os.makedirs(f"{self.boot}/new")
        with open(f"{self.boot}/new/cmdline.txt", "w") as f:
            f.write(cmdline_text(tuning="isolcpus=managed_irq,domain=0-3"))
        self.write_card_args("--yes")
        self.assertIn(NEW_TUNING, self.card())
        self.assertEqual(sorted(os.listdir(f"{self.boot}/new")), ["cmdline.txt"],
                         "a candidate in new/ is arm-try-piv.sh's to write, not this tool's")

    def test_without_os_prefix_it_is_the_root_cmdline(self):
        """A card with no os_prefix has no slots, so the file the firmware reads is the one in the
        root of the boot partition -- which is what this tool did before os_prefix was read. The
        directory the [tryboot] section names goes with it: nothing a normal boot reads is in it."""
        shutil.rmtree(self.live)
        self.write_config(ROOT_CONFIG)          # no os_prefix anywhere
        with open(self.root_cmdline(), "w") as f:
            f.write(cmdline_text())
        r = self.run_pb("status")
        self.assertIn(f"cmdline    {self.root_cmdline()}", r.stdout)
        self.write_card_args("--yes")
        self.assertIn(NEW_TUNING, self.read(self.root_cmdline()))
        backups = [os.path.basename(b) for b in glob.glob(self.root_cmdline() + ".bak-*")]
        self.assertLessEqual(len(backups), 1)
        self.assertEqual(sorted(os.listdir(self.boot)),
                         sorted(["cmdline.txt", "config.txt"] + backups),
                         "no current/ tree: the backup lands beside the file written")

    def test_an_os_prefix_that_names_no_directory_is_refused(self):
        shutil.rmtree(self.live)
        before_root = self.read(self.root_cmdline())
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("os_prefix=current", r.stderr)
        self.assertIn(f"{self.live} is not a directory", r.stderr)
        self.assertIn("refusing", r.stderr)
        self.assertFalse(os.path.exists(self.live), "a refusal writes nothing, not even a tree")
        self.assertEqual(self.read(self.root_cmdline()), before_root)
        self.assertEqual(self.backups(), [])

    def test_an_os_prefix_whose_tree_has_no_cmdline_is_refused(self):
        os.remove(self.card_path())
        r = self.run_pb("set-args", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"{self.live}/cmdline.txt does not exist", r.stderr)

    def test_status_shows_both_what_it_reads_and_what_it_would_write(self):
        r = self.run_pb("status")
        self.assertIn(f"cmdline    {self.live}/cmdline.txt", r.stdout)
        self.assertIn(f"writes     {self.live}/cmdline.txt", r.stdout)

    def test_set_args_says_which_file_before_it_writes_it(self):
        said = self.said(self.run_pb("set-args"))
        self.assertIn(self.live, said)
        said = self.said(self.write_card_args("--yes"))
        self.assertIn(self.live, said)

    def test_file_still_overrides_the_resolution(self):
        """The escape hatch stays an escape hatch: an operator who names a file means that file,
        and the tool prints it rather than the one os_prefix points at."""
        other = f"{self.boot}/somewhere-else.txt"
        with open(other, "w") as f:
            f.write(cmdline_text())
        r = self.run_pb("--file", other, "status")
        self.assertEqual(r.returncode, 0)
        self.assertIn(other, r.stdout)


class TestWhatARefusalSays(FakePiv):
    """Two different things, said as two different things: the exact arguments device.env requires
    and the line does not carry, and the safety keys the line has no argument for at all. The
    second used to go into the first as a literal `key<value>` token, which read as though the
    card were meant to hold that placeholder."""

    def test_a_refusal_says_which_arguments_are_missing_and_which_keys(self):
        self.write_card(cmdline_text().replace("rd.shell=0 ", ""))
        path = self.env_copy(DRACUT_SAFETY_ARGS="rd.shell=0 rd.emergency=reboot rd.retry=60 "
                                                "rd.timeout=90 rd.debug=1")
        r = self.run_pb("set-args", "--yes", check=False, env_path=path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rd.debug=1", r.stderr)
        self.assertIn("arguments", r.stderr, "the exact argument device.env asks for")
        self.assertIn("keys", r.stderr, "and the key the line has no argument for at all")
        # The two sentences are separate, so the key is reported as a key...
        self.assertIn("no argument for at all: rd.shell", r.stderr)
        # ...and the argument device.env asks for is reported among the arguments, twice over:
        # once as something to write and once as something the line lost.
        self.assertIn("missing from it: rd.shell=0", r.stderr)

    def test_the_word_value_cannot_appear_in_a_refusal(self):
        """The literal text `<value>` is not an argument and never was: it is a hole in a message
        that told whoever read it the card should contain a placeholder."""
        for broken in (cmdline_text().replace("rd.shell=0 ", ""),
                       cmdline_text().replace("rd.timeout=90 ", "")):
            self.write_card(broken)
            r = self.run_pb("set-args", "--yes", check=False)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("safety keys", r.stderr, "the refusal still says what is wrong")
            self.assertNotIn("<value>", self.said(r))

    def test_check_line_says_the_two_things_separately(self):
        """check_line is the one gate, so it is where the message is checked without a fake card."""
        with self.assertRaises(ValueError) as ctx:
            pb.check_line(cmdline_text().replace("rd.shell=0 ", "").split(), self.env)
        said = str(ctx.exception)
        self.assertIn("safety arguments that are missing from it: rd.shell=0", said)
        self.assertIn("safety keys it has no argument for at all: rd.shell", said)
        for key in pb.SAFETY_BASE:
            self.assertNotIn(f"{key}<value>", said)


class TestBackupAndRestore(FakePiv):
    def test_the_replaced_line_is_kept_beside_it_and_restored(self):
        before = self.card()
        self.write_card_args("--yes")
        self.assertEqual(len(self.backups()), 1)
        self.assertRegex(self.backups()[0], r"^cmdline\.txt\.bak-\d{8}T\d{6}Z$")
        self.assertEqual(self.read(f"{self.live}/{self.backups()[0]}"), before)
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
        stale = f"{self.live}/cmdline.txt.bak-20260101T000000Z"
        with open(stale, "w") as f:
            f.write(cmdline_text(root="root=LABEL=elsewhere", newline=True))
        r = self.run_pb("set-args", "--restore", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("root selector", r.stderr)
        self.assertIn("root=LABEL=writable", self.card())

        self.run_pb("set-args", "--restore", "--root", "LABEL=elsewhere")
        self.assertIn("root=LABEL=elsewhere", self.card())

    def test_restore_refuses_a_backup_that_lost_a_safety_argument(self):
        stale = f"{self.live}/cmdline.txt.bak-20260101T000000Z"
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
        self.write_card_args("--yes")
        tuned = self.card()
        r = self.run_pb("set-args", "--restore", "--dry-run")
        self.assertIn("-isolcpus=managed_irq,domain,1-3", r.stderr)
        self.assertIn("nothing written", r.stderr)
        self.assertEqual(self.card(), tuned)
        self.run_pb("set-args", "--restore")
        self.assertEqual(self.card(), before, "the backup is back, byte for byte")


class TestRestoringALineThisBootHasNotRun(FakePiv):
    """--restore is held to the same rule, and only when the line it would put back is not the one
    running now. The ordinary undo -- put back what the last write replaced, which is what this
    boot is running -- stays one command with no flag, so the way out of a bad line stays open."""

    def backup_of(self, tuning):
        """A backup holding a given tuning, shaped the way the tool writes them."""
        path = f"{self.live}/cmdline.txt.bak-20260101T000000Z"
        with open(path, "w") as f:
            f.write(cmdline_text(tuning=tuning, newline=True))
        return path

    def test_the_ordinary_undo_needs_no_flag(self):
        self.write_card_args("--yes")            # the card moves off the running line...
        self.run_pb("set-args", "--restore")     # ...and the undo puts it back
        self.assertIn(OLD_TUNING, self.card())

    def test_a_backup_this_boot_is_not_running_takes_the_flag(self):
        self.backup_of(NEW_TUNING)
        before = self.card()
        r = self.run_pb("set-args", "--restore", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--write-active-line", r.stderr)
        self.assertIn("make piv-audio-boot-args", r.stderr)
        self.assertEqual(self.card(), before, "a refused restore writes nothing")
        self.run_pb("set-args", "--restore", "--write-active-line")
        self.assertIn(NEW_TUNING, self.card())

    def test_restore_dry_run_shows_it_without_the_flag(self):
        self.backup_of(NEW_TUNING)
        before = self.card()
        r = self.run_pb("set-args", "--restore", "--dry-run")
        self.assertEqual(r.returncode, 0)
        self.assertIn("nothing written", r.stderr)
        self.assertIn("--write-active-line", r.stderr)
        self.assertEqual(self.card(), before)


class TestIdempotence(FakePiv):
    def test_running_it_twice_changes_nothing_and_adds_no_backup(self):
        self.write_card_args("--yes")
        once, backups = self.card(), list(self.backups())
        mtime = os.path.getmtime(self.card_path())
        r = self.run_pb("set-args", "--yes")
        self.assertIn("already says what device.env says", r.stderr)
        self.assertEqual(self.card(), once)
        self.assertEqual(self.backups(), backups, "no second backup for a line already in place")
        self.assertEqual(os.path.getmtime(self.card_path()), mtime)
        # and the card still has exactly one copy of each argument
        self.assertEqual(self.card_tokens().count("skew_tick=1"), 1)
        self.assertEqual(self.card().count("rd.emergency=reboot"), 1)

    def test_a_second_run_does_not_duplicate_the_tuned_arguments(self):
        """Move the card back to the old profile underneath the tool, as a board that was
        rewritten by hand would be, and check the rewrite is still not additive."""
        self.write_card_args("--yes")
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text(tuning=OLD_TUNING + " skew_tick=1"))
        self.write_card_args("--yes")
        tokens = self.card_tokens()
        self.assertEqual(tokens.count("skew_tick=1"), 1)
        self.assertEqual(tokens.count("irqaffinity=0"), 1)
        self.assertEqual([t for t in tokens if pb.is_tuning(t, pb.tuning_keys(self.env))],
                         NEW_TUNING.split())

    def test_the_backup_set_stays_bounded(self):
        """set-args is meant to be run repeatedly while a profile is worked out, and piv's boot
        partition is 505M: old command lines must not accumulate, however many runs it takes."""
        for _ in range(4):
            with open(self.card_path(), "w") as f:
                f.write(cmdline_text(tuning="isolcpus=managed_irq,domain=2-3"))
            self.write_card_args("--yes")
            self.write_card_args("--restore", "--yes")
        self.assertLessEqual(len(self.backups()), pb.KEEP_BACKUPS)
        self.assertGreaterEqual(len(self.backups()), 1)
        self.assertIn("isolcpus=managed_irq,domain=2-3", self.card())

    def test_two_writes_in_the_same_second_do_not_overwrite_each_others_backup(self):
        """The stamp has one-second resolution, and set-args is meant to be run twice in a row
        while a profile is worked out. The second run's backup must not land on the first one's,
        or --restore would put back the line it was supposed to undo."""
        old = self.card()
        self.write_card_args("--yes")
        tuned = self.card()
        self.assertNotEqual(old, tuned)
        with open(self.card_path(), "w") as f:
            f.write(cmdline_text(tuning="isolcpus=managed_irq,domain=1-2"))
        second = self.card()
        self.write_card_args("--yes")                     # a second write, same second
        self.assertEqual(self.card(), tuned)
        kept = [self.read(f"{self.live}/{b}") for b in self.backups()]
        self.assertIn(old, kept, "the line the first write replaced")
        self.assertIn(second, kept, "the line the second write replaced")
        self.assertEqual(len(set(self.backups())), len(self.backups()), "distinct names")

    def test_a_run_with_nothing_to_do_after_a_restore_is_quiet(self):
        before = self.card()
        self.write_card_args("--yes")
        self.run_pb("set-args", "--restore")
        r = self.run_pb("set-args", "--restore", "--yes")
        self.assertIn("already what", r.stderr)
        self.assertEqual(self.card(), before)


if __name__ == "__main__":
    unittest.main()
