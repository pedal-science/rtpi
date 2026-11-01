"""pro-boot, off the machine.

    python3 -m unittest discover -s tests/pro-boot -v

Each test builds a fake pro under a temporary PROBOOT_PREFIX: a /boot with two kernels "installed",
a grub.cfg naming the entries, a grubenv driven by stub `grub-*` commands on PATH, a /proc/cmdline
carrying whatever pedalboot.* markers the case needs, and a reboot command that records its
argument instead of rebooting.

The stubs matter as much as the tests. pro-boot's whole safety argument rests on `grub-reboot`
actually writing `next_entry` — on an LVM or RAID /boot it would succeed and change nothing, and a
trial would become a permanent boot — so there is a stub that accepts writes and silently drops
them, and a test that pro-boot refuses to arm against it.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import stat
import tempfile
import unittest
from argparse import Namespace

HERE = os.path.dirname(os.path.abspath(__file__))
RTPI = os.path.dirname(os.path.dirname(HERE))
PRO = os.path.join(RTPI, "devices", "pro")
PROBOOT = os.path.join(PRO, "usr/local/sbin/pro-boot")
ENV_FILE = os.path.join(PRO, "device.env")

STOCK = "7.0.0-42-generic"
RT = "7.0.0-38-realtime"
STOCK_ID = "gnulinux-simple-f27105cc-662c-4455-bb8e-6f5eae3d8250"
ISOL = "isolcpus=managed_irq,domain,1-5 nohz_full=1-5"

# A grubenv stub pair: `list` prints the file, `set`/`unset` edit it. DROP=1 makes every write a
# no-op, which is what a /boot GRUB cannot write behaves like.
EDITENV = """#!/bin/sh
f=$1; shift
[ -e "$f" ] || : > "$f"
case $1 in
  list) cat "$f" ;;
  set)  shift
        if [ "${DROP:-0}" = 1 ]; then exit 0; fi
        for kv in "$@"; do
          k=${kv%%=*}
          grep -v "^$k=" "$f" > "$f.new" 2>/dev/null || : > "$f.new"
          echo "$kv" >> "$f.new"; mv "$f.new" "$f"
        done ;;
  unset) shift
        if [ "${DROP:-0}" = 1 ]; then exit 0; fi
        for k in "$@"; do
          grep -v "^$k=" "$f" > "$f.new" 2>/dev/null || : > "$f.new"
          mv "$f.new" "$f"
        done ;;
esac
"""
# GRUB clears the one-shot by setting next_entry to the EMPTY string rather than removing it, so the
# stub does the same: a test that expected the variable to vanish would not match the real thing.
WRAPPER = """#!/bin/sh
exec grub-editenv "%s" set %s="$1"
"""


def write_exec(path, text):
    with open(path, "w") as handle:
        handle.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class FakePro(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="proboot-")
        r = self.root
        os.environ["PROBOOT_PREFIX"] = r
        for d in ("etc/rtpi", "boot/grub", "proc", "var/lib/rtpi/pro-boot", "lib/modules", "bin",
                  "usr/local/libexec"):
            os.makedirs(f"{r}/{d}", exist_ok=True)
        shutil.copy(ENV_FILE, f"{r}/etc/rtpi/device.env")
        for rel in (STOCK, RT):
            open(f"{r}/boot/vmlinuz-{rel}", "w").close()
            open(f"{r}/boot/initrd.img-{rel}", "w").close()
            os.makedirs(f"{r}/lib/modules/{rel}", exist_ok=True)
        self.write_grub_cfg(["pedal-tuned", "pedal-loose", STOCK_ID])
        open(f"{r}/boot/grub/grubenv", "w").close()
        self.set_promoted(kernel=STOCK, args="")
        self.set_cmdline("ro")

        # Stubs on PATH. The module caches nothing, so PATH is enough.
        bins = f"{r}/bin"
        write_exec(f"{bins}/grub-editenv", EDITENV)
        write_exec(f"{bins}/grub-reboot", WRAPPER % (f"{r}/boot/grub/grubenv", "next_entry"))
        write_exec(f"{bins}/grub-set-default", WRAPPER % (f"{r}/boot/grub/grubenv", "saved_entry"))
        write_exec(f"{bins}/uptime", "#!/bin/sh\necho 'up 1 minute'\n")
        os.environ["PATH"] = bins + os.pathsep + os.environ["PATH"]

        # PROBOOT_REBOOT is split on whitespace, so it has to be a command whose arguments contain
        # none: a script of its own rather than `sh -c '…'`.
        self.reboots = f"{r}/reboots"
        write_exec(f"{bins}/fake-reboot", "#!/bin/sh\necho rebooted >> %s\n" % self.reboots)
        os.environ["PROBOOT_REBOOT"] = f"{bins}/fake-reboot"

        # A stand-in for update-grub that does what 42_pedal does: write the two promoted entries,
        # Ubuntu's own, and the trial's — but only while a trial is marked trying. Without this the
        # tests could not catch the ordering that matters, which is that arming happens after the
        # entry exists and that a failed trial's entry is gone afterwards.
        write_exec(f"{bins}/fake-update-grub", f"""#!/bin/sh
cfg={r}/boot/grub/grub.cfg
state={r}/var/lib/rtpi/pro-boot
: > "$cfg"
for i in pedal-tuned pedal-loose {STOCK_ID}; do
  printf "menuentry 'x' \\$menuentry_id_option '%s' {{\\n}}\\n" "$i" >> "$cfg"
done
if grep -qx 'state=trying' "$state/trial" 2>/dev/null; then
  printf "menuentry 'x' \\$menuentry_id_option 'pedal-trial' {{\\n}}\\n" >> "$cfg"
fi
""")
        os.environ["PROBOOT_UPDATE_GRUB"] = f"{bins}/fake-update-grub"

        loader = importlib.machinery.SourceFileLoader("proboot", PROBOOT)
        spec = importlib.util.spec_from_loader("proboot", loader)
        self.pb = importlib.util.module_from_spec(spec)
        loader.exec_module(self.pb)
        self.env = self.pb.device_env()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)
        for key in ("PROBOOT_PREFIX", "PROBOOT_REBOOT", "PROBOOT_UPDATE_GRUB"):
            os.environ.pop(key, None)

    # ---------------------------------------------------------------- helpers
    def write_grub_cfg(self, ids):
        with open(f"{self.root}/boot/grub/grub.cfg", "w") as handle:
            for i in ids:
                handle.write("menuentry 'x' $menuentry_id_option '%s' {\n}\n" % i)

    def set_cmdline(self, text):
        with open(f"{self.root}/proc/cmdline", "w") as handle:
            handle.write(text + "\n")

    def set_promoted(self, **values):
        self.pb_write("promoted", values)

    def set_trial(self, **values):
        self.pb_write("trial", values)

    def pb_write(self, name, values):
        with open(f"{self.root}/var/lib/rtpi/pro-boot/{name}", "w") as handle:
            for k, v in values.items():
                handle.write("%s=%s\n" % (k, v))

    def read_conf(self, name):
        path = f"{self.root}/var/lib/rtpi/pro-boot/{name}"
        if not os.path.exists(path):
            return None
        out = {}
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    out[k] = v
        return out

    def grubenv(self):
        out = {}
        with open(f"{self.root}/boot/grub/grubenv") as handle:
            for line in handle:
                if "=" in line:
                    k, _, v = line.strip().partition("=")
                    out[k] = v
        return out

    def hook(self, exit_code):
        write_exec(f"{self.root}/usr/local/libexec/pro-boot-validate",
                   "#!/bin/sh\nexit %d\n" % exit_code)

    def rebooted(self):
        return os.path.exists(self.reboots)


class TryArmsOneShot(FakePro):
    def test_try_writes_the_trial_and_arms_next_entry(self):
        self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)
        trial = self.read_conf("trial")
        self.assertEqual(trial["kernel"], RT)
        self.assertEqual(trial["args"], ISOL)
        self.assertEqual(trial["state"], "trying")
        self.assertEqual(self.grubenv()["next_entry"], "pedal-trial")
        # Arming must not change what the machine boots by default.
        self.assertNotIn("saved_entry", self.grubenv())

    def test_try_refuses_when_grubenv_cannot_be_written(self):
        """The one failure that would turn a trial into a permanent boot."""
        os.environ["DROP"] = "1"
        try:
            with self.assertRaises(SystemExit):
                self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)
        finally:
            os.environ.pop("DROP")
        self.assertNotIn("next_entry", self.grubenv())

    def test_try_refuses_a_second_trial_while_one_is_untested(self):
        self.set_trial(kernel=RT, args=ISOL, state="trying")
        with self.assertRaises(SystemExit):
            self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)

    def test_try_refuses_on_a_trial_boot(self):
        self.set_cmdline("ro pedalboot.profile=trial pedalboot.entry=pedal-trial")
        with self.assertRaises(SystemExit):
            self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)

    def test_try_refuses_a_kernel_that_is_not_installed(self):
        with self.assertRaises(SystemExit):
            self.pb.cmd_try(Namespace(kernel="9.9.9-nope", args="", no_reboot=True), self.env)

    def test_try_refuses_with_no_fallback_kernel(self):
        os.unlink(f"{self.root}/boot/vmlinuz-{STOCK}")
        with self.assertRaises(SystemExit):
            self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)

    def test_try_refuses_when_ubuntus_own_entry_is_gone(self):
        self.write_grub_cfg(["pedal-tuned", "pedal-loose"])
        with self.assertRaises(SystemExit):
            self.pb.cmd_try(Namespace(kernel=RT, args=ISOL, no_reboot=True), self.env)


class ValidatePromotes(FakePro):
    def setUp(self):
        super().setUp()
        self.set_cmdline("ro pedalboot.profile=trial pedalboot.entry=pedal-trial")
        self.set_trial(kernel=RT, args=ISOL, state="trying")

    def test_a_passing_hook_promotes_and_leaves_no_trial(self):
        self.hook(0)
        self.assertEqual(self.pb.cmd_validate(Namespace(), self.env), 0)
        promoted = self.read_conf("promoted")
        self.assertEqual(promoted["kernel"], RT)
        self.assertEqual(promoted["args"], ISOL)
        self.assertIsNone(self.read_conf("trial"))
        self.assertEqual(self.grubenv()["saved_entry"], "pedal-tuned")
        self.assertFalse(self.rebooted())

    def test_a_failing_hook_marks_it_bad_and_reboots(self):
        self.hook(1)
        self.assertEqual(self.pb.cmd_validate(Namespace(), self.env), 1)
        self.assertEqual(self.read_conf("trial")["state"], "bad")
        self.assertIn("reason", self.read_conf("trial"))
        # What pro boots has NOT changed: the fallback is whatever was saved before.
        self.assertEqual(self.read_conf("promoted")["kernel"], STOCK)
        self.assertNotIn("saved_entry", self.grubenv())
        self.assertTrue(self.rebooted())

    def test_validate_does_nothing_on_a_normal_boot(self):
        self.set_cmdline("ro pedalboot.profile=tuned")
        self.hook(1)
        self.assertEqual(self.pb.cmd_validate(Namespace(), self.env), 0)
        self.assertEqual(self.read_conf("trial")["state"], "trying")
        self.assertFalse(self.rebooted())


class SettleAndDeadline(FakePro):
    def test_settle_fails_a_trial_that_never_validated(self):
        self.set_trial(kernel=RT, args=ISOL, state="trying")
        self.set_cmdline("ro pedalboot.profile=tuned")
        self.pb.cmd_settle(Namespace(), self.env)
        self.assertEqual(self.read_conf("trial")["state"], "bad")
        self.assertIn("never validated", self.read_conf("trial")["reason"])

    def test_settle_leaves_the_trial_alone_on_its_own_boot(self):
        self.set_trial(kernel=RT, args=ISOL, state="trying")
        self.set_cmdline("ro pedalboot.profile=trial")
        self.pb.cmd_settle(Namespace(), self.env)
        self.assertEqual(self.read_conf("trial")["state"], "trying")

    def test_settle_is_quiet_with_nothing_armed(self):
        self.set_cmdline("ro pedalboot.profile=tuned")
        self.assertEqual(self.pb.cmd_settle(Namespace(), self.env), 0)

    def test_deadline_does_nothing_once_the_trial_was_promoted(self):
        self.set_cmdline("ro pedalboot.profile=trial")
        self.assertEqual(self.pb.cmd_deadline(Namespace(after=0), self.env), 0)
        self.assertFalse(self.rebooted())

    def test_deadline_fails_a_trial_that_is_still_trying(self):
        self.set_cmdline("ro pedalboot.profile=trial")
        self.set_trial(kernel=RT, args=ISOL, state="trying")
        self.assertEqual(self.pb.cmd_deadline(Namespace(after=0), self.env), 1)
        self.assertEqual(self.read_conf("trial")["state"], "bad")
        self.assertTrue(self.rebooted())

    def test_deadline_does_nothing_on_a_normal_boot(self):
        self.set_cmdline("ro pedalboot.profile=tuned")
        self.set_trial(kernel=RT, args=ISOL, state="trying")
        self.assertEqual(self.pb.cmd_deadline(Namespace(after=0), self.env), 0)
        self.assertFalse(self.rebooted())


class Defaults(FakePro):
    def test_default_stock_names_ubuntus_own_entry(self):
        self.pb.cmd_default(Namespace(which="stock"), self.env)
        self.assertEqual(self.grubenv()["saved_entry"], STOCK_ID)

    def test_default_tuned_and_loose(self):
        self.pb.cmd_default(Namespace(which="tuned"), self.env)
        self.assertEqual(self.grubenv()["saved_entry"], "pedal-tuned")
        self.pb.cmd_default(Namespace(which="loose"), self.env)
        self.assertEqual(self.grubenv()["saved_entry"], "pedal-loose")

    def test_a_default_that_is_not_in_the_menu_is_refused(self):
        self.write_grub_cfg([STOCK_ID])
        with self.assertRaises(SystemExit):
            self.pb.cmd_default(Namespace(which="tuned"), self.env)

    def test_loose_refuses_without_the_maintenance_target(self):
        with self.assertRaises(SystemExit):
            self.pb.cmd_loose(Namespace(no_reboot=True), self.env)

    def test_loose_arms_the_one_shot_when_the_target_is_there(self):
        os.makedirs(f"{self.root}/etc/systemd/system", exist_ok=True)
        open(f"{self.root}/etc/systemd/system/pedal-maint.target", "w").close()
        self.pb.cmd_loose(Namespace(no_reboot=True), self.env)
        self.assertEqual(self.grubenv()["next_entry"], "pedal-loose")


class SetArgs(FakePro):
    def test_set_args_needs_yes_and_then_writes_and_restores(self):
        wanted = self.env["AUDIO_TUNING_ARGS"]
        self.assertEqual(self.pb.cmd_set_args(Namespace(yes=False, restore=False), self.env), 2)
        self.assertEqual(self.read_conf("promoted")["args"], "")
        self.assertEqual(self.pb.cmd_set_args(Namespace(yes=True, restore=False), self.env), 0)
        self.assertEqual(self.read_conf("promoted")["args"], wanted)
        self.assertEqual(self.pb.cmd_set_args(Namespace(yes=True, restore=True), self.env), 0)
        self.assertEqual(self.read_conf("promoted")["args"], "")

    def test_restore_with_nothing_to_restore_is_refused(self):
        with self.assertRaises(SystemExit):
            self.pb.cmd_set_args(Namespace(yes=True, restore=True), self.env)


class DeviceEnvAgrees(FakePro):
    """The boot half and the runtime half must name the same cores. pedal-tune checks this on the
    host at every boot; this catches it in the repo, where it is cheaper to notice."""

    def test_isolation_arguments_name_the_same_cores_as_pedal_tune(self):
        args = self.env["AUDIO_TUNING_ARGS"]
        isolcpus = [w for w in args.split() if w.startswith("isolcpus=")][0]
        cores = isolcpus.split("=", 1)[1].split(",")[-1]
        for word in ("nohz_full", "rcu_nocbs"):
            got = [w for w in args.split() if w.startswith(word + "=")][0].split("=", 1)[1]
            self.assertEqual(got, cores, "%s must cover the same cores as isolcpus" % word)

        tune = os.path.join(RTPI, "..", "pedal.project", "devices", "pro",
                            "rootfs/etc/pedal/tune.conf")
        if not os.path.exists(tune):
            self.skipTest("pedal.project is not beside rtpi in this checkout")
        values = {}
        with open(tune) as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    values[k] = v.strip().strip('"')
        self.assertEqual(values["ISOLATED_CPUS"], cores,
                         "tune.conf's ISOLATED_CPUS must match the kernel command line")
        self.assertIn(values["RT_CPUS"], cores.split("-"),
                      "the active render core must be inside the isolated set")
        self.assertNotIn(values["HOUSEKEEPING_CPUS"], cores.split("-"),
                         "the housekeeping core must not be in the isolated set")
        self.assertEqual(
            [w for w in args.split() if w.startswith("irqaffinity=")][0].split("=", 1)[1],
            values["HOUSEKEEPING_CPUS"],
            "irqaffinity must default interrupts to the housekeeping core")


if __name__ == "__main__":
    unittest.main()
