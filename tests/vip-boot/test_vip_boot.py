"""vip-boot and the vip-guard initramfs hook, off the board.

    python3 -m unittest discover -s tests/vip-boot -v      (Linux: run it in the build container)

Each test builds a fake vip under a temporary VIPBOOT_PREFIX: bootsel and the pedal boot partition
made by vip-boot's own init-* commands, a device tree saying whether the tryboot flag is set, a
/proc/cmdline with vipboot.* markers, a kernel "installed" under /boot, and a reboot command that
records its argument instead of rebooting.
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
VIP = os.path.join(RTPI, "devices", "vip")
VIPBOOT = os.path.join(VIP, "usr/local/sbin/vip-boot")
GUARD = os.path.join(VIP, "usr/lib/dracut/modules.d/95vip-guard/vip-guard.sh")
ENV = os.path.join(VIP, "device.env")

loader = importlib.machinery.SourceFileLoader("vipboot", VIPBOOT)
spec = importlib.util.spec_from_loader("vipboot", loader)
vb = importlib.util.module_from_spec(spec)
loader.exec_module(vb)

OLD, NEW = "7.0.0-1017-raspi-realtime", "7.0.0-1020-raspi-realtime"


class FakeVip(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vipboot-")
        self.env = vb.read_env(ENV)
        r = self.root
        os.makedirs(f"{r}/etc/rtpi")
        shutil.copy(ENV, f"{r}/etc/rtpi/device.env")
        os.makedirs(f"{r}/run")
        os.makedirs(f"{r}/proc/device-tree/chosen/bootloader")
        for rel in (OLD, NEW):
            self.install_kernel(rel)
        self.reboots = f"{r}/reboots"
        with open(f"{r}/reboot", "w") as f:
            f.write(f'#!/bin/sh\necho "${{1:-<plain>}}" >> {self.reboots}\n')
        os.chmod(f"{r}/reboot", 0o755)
        os.makedirs(f"{r}/usr/local/libexec")
        self.set_validate(True)
        os.makedirs(f"{r}/usr/lib/systemd/system")
        with open(f"{r}/usr/lib/systemd/system/pedal-maint.target", "w") as f:
            f.write("[Unit]\n")
        # The partitions, as the image build makes them.
        self.bootsel = r + self.env["BOOTSEL_MOUNT"]
        self.boot = r + self.env["PEDAL_BOOT_MOUNT"]
        self.rescue = f"{r}/boot/rescue-boot"   # the rescue partition is mounted only when booting it
        self.run_vb("init-bootsel", "--dir", self.bootsel)
        self.run_vb("init-pedal-boot", "--dir", self.boot, "--kernel-root", r, "--release", OLD)
        self.run_vb("init-rescue-boot", "--dir", self.rescue, "--kernel-root", r, "--release", OLD)
        self.boot_as(slot="a", profile="tuned", tryboot=False)

    def tearDown(self):
        shutil.rmtree(self.root)

    # --- the fake board
    def install_kernel(self, rel):
        r = self.root
        os.makedirs(f"{r}/boot", exist_ok=True)
        for f in (f"vmlinuz-{rel}", f"initrd.img-{rel}"):
            with open(f"{r}/boot/{f}", "w") as fh:
                fh.write(f"{f}\n")
        dt = f"{r}/usr/lib/firmware/{rel}/device-tree"
        os.makedirs(f"{dt}/broadcom")
        os.makedirs(f"{dt}/overlays")
        for f in ("bcm2712-rpi-5-b.dtb", "bcm2712d0-rpi-5-b.dtb", "bcm2711-rpi-4-b.dtb"):
            with open(f"{dt}/broadcom/{f}", "w") as fh:
                fh.write(rel)
        with open(f"{dt}/overlays/vc4-kms-v3d.dtbo", "w") as fh:
            fh.write(rel)

    def boot_as(self, slot=None, profile="tuned", tryboot=False, root="pedal"):
        marks = f"vipboot.root={root}" + (f" vipboot.slot={slot} vipboot.profile={profile}" if slot else "")
        extra = " systemd.unit=pedal-maint.target" if profile == "loose" else ""
        with open(f"{self.root}/proc/cmdline", "w") as f:
            f.write(f"root=LABEL=x{extra} {marks}\n")
        with open(f"{self.root}/proc/device-tree/chosen/bootloader/tryboot", "wb") as f:
            f.write((1 if tryboot else 0).to_bytes(4, "big"))
        with open(f"{self.root}/proc/device-tree/chosen/bootloader/partition", "wb") as f:
            f.write(int(self.env["PEDAL_BOOT_PART"] if root == "pedal" else self.env["RESCUE_BOOT_PART"]).to_bytes(4, "big"))

    def set_validate(self, passes):
        hook = f"{self.root}/usr/local/libexec/vip-boot-validate"
        with open(hook, "w") as f:
            f.write(f"#!/bin/sh\necho \"$1\" > {self.root}/validated\nexit {0 if passes else 1}\n")
        os.chmod(hook, 0o755)

    def run_vb(self, *args, check=True):
        env = dict(os.environ, VIPBOOT_PREFIX=self.root, VIPBOOT_NO_MOUNT="1",
                   VIPBOOT_REBOOT=f"{self.root}/reboot")
        r = subprocess.run(["python3", VIPBOOT, "--env", ENV, *args], env=env,
                           capture_output=True, text=True)
        if check and r.returncode:
            self.fail(f"vip-boot {' '.join(args)} failed: {r.stderr}")
        return r

    def run_guard(self):
        env = dict(os.environ, VIPGUARD_PREFIX=self.root, VIPGUARD_NO_MOUNT="1",
                   VIPGUARD_REBOOT=f"{self.root}/reboot")
        # The hook mounts bootsel at /run/vip-guard: point that at the fake bootsel.
        link = f"{self.root}/run/vip-guard"
        if not os.path.islink(link):
            os.symlink(self.bootsel, link)
        return subprocess.run(["sh", GUARD], env=env, capture_output=True, text=True)

    # --- reading it back
    def read(self, path):
        with open(path) as f:
            return f.read()

    def profile(self):
        return vb.parse_profile(self.read(f"{self.boot}/profile.txt"))

    def state(self, slot):
        return self.read(f"{self.boot}/{slot}/state").strip()

    def armed(self):
        return [l for l in self.read(f"{self.boot}/tryboot.txt").splitlines() if l and not l.startswith("#")]

    def reboots_seen(self):
        return self.read(self.reboots).split("\n")[:-1] if os.path.exists(self.reboots) else []

    def count(self):
        return self.read(f"{self.bootsel}/vipboot/count")

    def default_part(self):
        return vb.parse_autoboot(self.read(f"{self.bootsel}/autoboot.txt"))

    def sizes(self):
        files = [f"{self.boot}/profile.txt", f"{self.boot}/tryboot.txt", f"{self.bootsel}/autoboot.txt",
                 f"{self.bootsel}/vipboot/count", f"{self.bootsel}/vipboot/reason"]
        return {f: os.path.getsize(f) for f in files}


class TestImage(FakeVip):
    def test_init_layout(self):
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual((self.state("a"), self.state("b")), ("good", "empty"))
        self.assertEqual(self.armed(), [])
        self.assertEqual(self.default_part(), self.env["PEDAL_BOOT_PART"])
        cfg = self.read(f"{self.boot}/config.txt")
        self.assertLess(cfg.index("include profile.txt"), cfg.index("[tryboot]"))
        self.assertLess(cfg.index("[tryboot]"), cfg.index("include tryboot.txt"))
        # the kernel settings apply to every boot, not only tryboot ones
        tail = cfg[cfg.index("include tryboot.txt"):]
        self.assertLess(tail.index("[all]"), tail.index("kernel=vmlinuz"))
        # The Pico's link UART, for every boot: the stock DT ships RP1's UART0 disabled, and
        # enable_uart=1 alone left the pedal without /dev/ttyAMA0 after a card rewrite
        # (pedal.project bench-results/2026-10-05-header-uart-disabled.md).
        self.assertIn("enable_uart=1", tail)
        self.assertIn("dtoverlay=uart0", tail)
        rescue = self.read(f"{self.rescue}/config.txt")
        self.assertIn("enable_uart=1", rescue)
        self.assertIn("dtoverlay=uart0", rescue)
        self.assertIn("cmdline=cmdline.txt", rescue)
        a = f"{self.boot}/a"
        self.assertTrue(os.path.exists(f"{a}/bcm2712-rpi-5-b.dtb"))
        self.assertFalse(os.path.exists(f"{a}/bcm2711-rpi-4-b.dtb"))
        self.assertTrue(os.path.exists(f"{a}/overlays/vc4-kms-v3d.dtbo"))
        tuned = self.read(f"{a}/cmdline-tuned.txt")
        loose = self.read(f"{a}/cmdline-loose.txt")
        self.assertIn(self.env["AUDIO_TUNING_ARGS"], tuned)
        self.assertNotIn("isolcpus", loose)
        self.assertIn("systemd.unit=pedal-maint.target", loose)
        for c in (tuned, loose):
            self.assertIn("net.ifnames=0", c)
            self.assertIn("rd.emergency=reboot", c)
            self.assertIn("vipboot.slot=a", c)
            self.assertTrue(c.startswith("root=LABEL=pedal "))
            self.assertEqual(c.count("\n"), 1)

    # --- both slots filled: the pedal's kernel and the stock fallback -------------------------
    def init_with_fallback(self, fallback=NEW, release=OLD, check=True):
        return self.run_vb("init-pedal-boot", "--dir", self.boot, "--kernel-root", self.root,
                           "--release", release, "--fallback-release", fallback, check=check)

    def test_fallback_slot_is_a_complete_slot(self):
        self.init_with_fallback()
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual((self.state("a"), self.state("b")), ("good", "good"))
        self.assertEqual(self.read(f"{self.boot}/a/kernel.release").strip(), OLD)
        self.assertEqual(self.read(f"{self.boot}/b/kernel.release").strip(), NEW)
        for f in ("vmlinuz", "initrd.img", "bcm2712-rpi-5-b.dtb", "cmdline-tuned.txt",
                  "cmdline-loose.txt", "tuned.args"):
            self.assertTrue(os.path.exists(f"{self.boot}/b/{f}"), f)
        self.assertTrue(os.path.exists(f"{self.boot}/b/overlays/vc4-kms-v3d.dtbo"))
        b = self.read(f"{self.boot}/b/cmdline-tuned.txt")
        self.assertIn("vipboot.slot=b", b)
        self.assertIn(self.env["AUDIO_TUNING_ARGS"], b)

    def test_the_fallback_can_be_tried_and_promoted(self):
        """The whole point of filling it at image build: a validated way back to a kernel that
        is known to work, without a card reader."""
        self.init_with_fallback()
        self.run_vb("try-kernel", NEW, "--no-reboot")
        self.assertEqual(self.armed(), ["os_prefix=b/"])
        self.assertEqual(self.state("b"), "trying")
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("validate")
        self.assertEqual(self.profile(), ("b", "tuned"))
        self.assertEqual((self.state("a"), self.state("b")), ("good", "good"))
        self.assertEqual(self.read(f"{self.boot}/a/kernel.release").strip(), OLD)
        self.assertEqual(self.read(self.root + "/validated").strip(), NEW)

    def test_fallback_must_differ_from_the_pedal_kernel(self):
        r = self.init_with_fallback(fallback=OLD, release=OLD, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("fallback release is the pedal's own", r.stderr)

    def test_fallback_must_be_installed_in_the_root(self):
        r = self.run_vb("init-pedal-boot", "--dir", self.boot, "--kernel-root", self.root,
                        "--release", OLD, "--fallback-release", "9.9.9-nope", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotEqual(self.state("b"), "good", "a slot that was never filled is not good")

    def test_fixed_sizes(self):
        self.assertEqual(self.sizes()[f"{self.boot}/profile.txt"], vb.SMALL)
        self.assertEqual(self.sizes()[f"{self.bootsel}/vipboot/count"], vb.COUNT_W)
        for f in self.sizes():
            self.assertLessEqual(os.path.getsize(f), 512, f"{f} must fit one sector")

    def test_autoboot_one_length(self):
        self.assertEqual(len(vb.autoboot_text(2, 2)), len(vb.autoboot_text(3, 2)))
        with self.assertRaises(ValueError):
            vb.autoboot_text(10, 2)


class TestCandidates(FakeVip):
    def test_try_kernel_arms_spare_slot(self):
        before = self.sizes()
        self.run_vb("try-kernel", NEW)
        self.assertEqual(self.state("b"), "trying")
        self.assertEqual(self.read(f"{self.boot}/b/kernel.release").strip(), NEW)
        self.assertEqual(self.read(f"{self.boot}/b/vmlinuz"), f"vmlinuz-{NEW}\n")
        self.assertEqual(self.armed(), ["os_prefix=b/"])
        self.assertEqual(self.profile(), ("a", "tuned"), "arming must not change the default")
        self.assertEqual(self.reboots_seen(), ["0 tryboot"])
        self.assertEqual(self.sizes(), before)

    def test_validate_pass_promotes(self):
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("validate")
        self.assertEqual(self.read(f"{self.root}/validated").strip(), NEW)
        self.assertEqual(self.profile(), ("b", "tuned"))
        self.assertEqual(self.state("b"), "good")
        self.assertEqual(self.state("a"), "good", "the previous kernel stays as the fallback")
        self.assertEqual(self.armed(), [])
        self.assertEqual(self.reboots_seen(), ["0 tryboot"], "a pass does not reboot")

    def test_validate_fail_rolls_back(self):
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="b", tryboot=True)
        self.set_validate(False)
        self.run_vb("validate")
        self.assertEqual(self.state("b"), "bad")
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual(self.reboots_seen(), ["0 tryboot", "<plain>"])
        self.assertIn("failed validation", self.read(f"{self.bootsel}/vipboot/reason"))

    def test_settle_after_hang(self):
        """The candidate hung into the watchdog: the reset is a normal boot, back on slot a."""
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="a", tryboot=False)
        self.run_vb("settle")
        self.assertEqual(self.state("b"), "bad")
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual(self.armed(), [])
        self.assertIn("never validated", self.read(f"{self.bootsel}/vipboot/reason"))

    def test_settle_leaves_a_candidate_alone_on_its_own_boot(self):
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("settle")
        self.assertEqual(self.state("b"), "trying")

    def test_try_again_after_a_bad_one(self):
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="a")
        self.run_vb("settle")
        self.run_vb("try-kernel", NEW)
        self.assertEqual(self.state("b"), "trying")

    def test_second_promotion_uses_the_other_slot(self):
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("validate")
        self.boot_as(slot="b")
        self.run_vb("try-kernel", OLD)
        self.assertEqual(self.armed(), ["os_prefix=a/"])
        self.assertEqual(self.read(f"{self.boot}/a/kernel.release").strip(), OLD)
        self.assertIn("vipboot.slot=a", self.read(f"{self.boot}/a/cmdline-tuned.txt"))

    def test_refuses_from_a_tryboot(self):
        self.boot_as(slot="a", tryboot=True)
        r = self.run_vb("try-kernel", NEW, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.state("b"), "empty")

    def test_refuses_when_active_is_not_good(self):
        with open(f"{self.boot}/a/state", "r+") as f:
            f.write(vb.state_text("bad"))
        r = self.run_vb("try-kernel", NEW, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.armed(), [])

    def test_refuses_from_rescue(self):
        self.boot_as(root="rescue")
        self.assertNotEqual(self.run_vb("try-kernel", NEW, check=False).returncode, 0)

    def test_refuses_a_kernel_that_is_not_installed(self):
        r = self.run_vb("try-kernel", "9.9.9-nope", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.armed(), [])
        self.assertEqual(self.reboots_seen(), [])

    def test_try_args(self):
        self.run_vb("try-args", "isolcpus=3  nohz_full=3")
        self.assertEqual(self.read(f"{self.boot}/b/kernel.release").strip(), OLD)
        self.assertEqual(self.read(f"{self.boot}/b/vmlinuz"), f"vmlinuz-{OLD}\n")
        tuned = self.read(f"{self.boot}/b/cmdline-tuned.txt")
        self.assertIn(" isolcpus=3 nohz_full=3 ", tuned)
        self.assertNotIn("rcu_nocbs", tuned)
        self.assertIn("systemd.unit=pedal-maint.target", self.read(f"{self.boot}/b/cmdline-loose.txt"))
        self.assertEqual(self.armed(), ["os_prefix=b/"])
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("validate")
        self.assertEqual(self.profile(), ("b", "tuned"))


class TestProfilesAndRoots(FakeVip):
    def test_loose_once(self):
        self.run_vb("loose")
        self.assertEqual(self.armed(), ["cmdline=cmdline-loose.txt"])
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual(self.reboots_seen(), ["0 tryboot"])
        # its boot: nothing to validate, nothing promoted
        self.boot_as(slot="a", profile="loose", tryboot=True)
        self.run_vb("validate")
        self.assertFalse(os.path.exists(f"{self.root}/validated"))
        self.assertEqual(self.profile(), ("a", "tuned"))
        # the next normal boot disarms it
        self.boot_as(slot="a")
        self.run_vb("settle")
        self.assertEqual(self.armed(), [])

    def test_loose_refused_without_its_target(self):
        os.remove(f"{self.root}/usr/lib/systemd/system/pedal-maint.target")
        self.assertNotEqual(self.run_vb("loose", check=False).returncode, 0)
        self.assertNotEqual(self.run_vb("default", "loose", check=False).returncode, 0)
        self.assertEqual(self.armed(), [])
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual(self.reboots_seen(), [])

    def test_default_profile(self):
        before = self.sizes()
        self.run_vb("default", "loose")
        self.assertEqual(self.profile(), ("a", "loose"))
        self.run_vb("default", "tuned")
        self.assertEqual(self.profile(), ("a", "tuned"))
        self.assertEqual(self.sizes(), before)
        self.assertEqual(self.reboots_seen(), [])

    def test_candidate_keeps_the_default_profile(self):
        self.run_vb("default", "loose")
        self.run_vb("try-kernel", NEW)
        self.boot_as(slot="b", profile="loose", tryboot=True)
        self.run_vb("validate")
        self.assertEqual(self.profile(), ("b", "loose"))

    def test_rescue_once(self):
        self.run_vb("rescue")
        self.assertEqual(self.reboots_seen(), [self.env["RESCUE_BOOT_PART"]])
        self.assertEqual(self.default_part(), self.env["PEDAL_BOOT_PART"], "once means nothing written")

    def test_rescue_stay_and_back(self):
        before = self.sizes()
        self.run_vb("rescue", "--stay")
        self.assertEqual(self.default_part(), self.env["RESCUE_BOOT_PART"])
        self.assertEqual(self.reboots_seen(), ["<plain>"])
        self.boot_as(root="rescue")
        self.run_vb("default", "pedal")
        self.assertEqual(self.default_part(), self.env["PEDAL_BOOT_PART"])
        self.assertEqual(self.sizes(), before)

    def test_try_pedal_from_rescue_leaves_rescue_the_default(self):
        self.boot_as(root="rescue")
        self.run_vb("stay")
        self.run_vb("try-pedal")
        self.assertEqual(self.reboots_seen(), [self.env["PEDAL_BOOT_PART"]])
        self.assertEqual(self.default_part(), self.env["RESCUE_BOOT_PART"])

    def test_try_pedal_refused_on_the_pedal(self):
        r = self.run_vb("try-pedal", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.reboots_seen(), [])

    def test_stay_from_rescue(self):
        self.boot_as(root="rescue")
        self.run_vb("stay")
        self.assertEqual(self.default_part(), self.env["RESCUE_BOOT_PART"])

    def test_status_runs(self):
        r = self.run_vb("status")
        self.assertIn("slot a *", r.stdout)
        self.assertIn("default    root=pedal slot=a profile=tuned", r.stdout)


class TestGuard(FakeVip):
    def test_counts_then_falls_back(self):
        limit = int(self.env["GUARD_LIMIT"])
        before = self.sizes()
        for n in range(1, limit + 1):
            r = self.run_guard()
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.count(), vb.count_text(n))
            self.assertEqual(self.default_part(), self.env["PEDAL_BOOT_PART"])
        self.assertEqual(self.reboots_seen(), [])
        self.run_guard()
        self.assertEqual(self.default_part(), self.env["RESCUE_BOOT_PART"])
        self.assertEqual(self.read(f"{self.bootsel}/autoboot.txt"),
                         vb.autoboot_text(self.env["RESCUE_BOOT_PART"], self.env["PEDAL_BOOT_PART"]))
        self.assertEqual(self.count(), vb.count_text(0))
        self.assertIn("rescue made the default", self.read(f"{self.bootsel}/vipboot/reason"))
        self.assertEqual(self.reboots_seen(), ["<plain>"])
        self.assertEqual(self.sizes(), before)

    def test_deadline_reboots_a_boot_that_never_reached_the_guard(self):
        self.run_guard()                                   # the initramfs counted this boot
        self.run_vb("deadline", "--after", "0")
        self.assertEqual(self.reboots_seen(), ["<plain>"])
        self.assertIn("hadn't reached pedal-guard", self.read(f"{self.bootsel}/vipboot/reason"))
        self.assertEqual(self.count(), vb.count_text(1))  # the next boot's initramfs adds to it

    def test_deadline_leaves_a_guarded_boot_alone(self):
        self.run_guard()
        self.run_vb("guard-clear")                         # the engine came up
        self.run_vb("deadline", "--after", "0")
        self.assertEqual(self.reboots_seen(), [])

    def test_deadline_leaves_candidates_and_rescue_alone(self):
        self.run_guard()
        self.boot_as(slot="b", tryboot=True)
        self.run_vb("deadline", "--after", "0")
        self.boot_as(root="rescue")
        self.run_vb("deadline", "--after", "0")
        self.assertEqual(self.reboots_seen(), [])

    def test_deadline_does_not_hold_the_lock_while_it_waits(self):
        # pedal-guard's guard-clear must get through during the wait, or the deadline would reboot
        # a pedal that reached its engine.
        self.run_guard()
        env = dict(os.environ, VIPBOOT_PREFIX=self.root, VIPBOOT_NO_MOUNT="1",
                   VIPBOOT_REBOOT=f"{self.root}/reboot")
        waiting = subprocess.Popen(["python3", VIPBOOT, "--env", ENV, "deadline", "--after", "3"], env=env)
        try:
            time.sleep(0.5)
            start = time.time()
            self.run_vb("guard-clear")
            self.assertLess(time.time() - start, 2)
        finally:
            waiting.wait(timeout=10)
        self.assertEqual(self.reboots_seen(), [])

    def fake_systemctl(self, script):
        path = f"{self.root}/systemctl"
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + script)
        os.chmod(path, 0o755)
        return path

    def run_clear(self, systemctl, *extra):
        env = dict(os.environ, VIPBOOT_PREFIX=self.root, VIPBOOT_NO_MOUNT="1",
                   VIPBOOT_REBOOT=f"{self.root}/reboot", VIPBOOT_SYSTEMCTL=systemctl)
        return subprocess.run(["python3", VIPBOOT, "--env", ENV, "guard-clear", "--require-unit", "namchaind.service",
                               *extra], env=env, capture_output=True, text=True)

    def test_guard_clear_waits_for_the_unit_to_stay_up(self):
        self.run_guard()
        stable = self.fake_systemctl('echo ActiveState=active; echo InvocationID=abc\n')
        r = self.run_clear(stable, "--settle", "1", "--wait", "5")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.count(), vb.count_text(0))

    def test_guard_clear_refuses_a_unit_that_keeps_restarting(self):
        # Active at every look, but a new run each time: namchaind failing and restarting.
        self.run_guard()
        flapping = self.fake_systemctl('echo ActiveState=active; echo InvocationID=$(date +%s%N)\n')
        r = self.run_clear(flapping, "--settle", "1", "--wait", "3")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.count(), vb.count_text(1))

    def test_guard_clear_resets(self):
        self.run_guard()
        self.run_guard()
        self.run_vb("guard-clear")
        self.assertEqual(self.count(), vb.count_text(0))
        self.run_guard()
        self.assertEqual(self.count(), vb.count_text(1))

    def test_candidate_not_counted(self):
        self.boot_as(slot="b", tryboot=True)
        self.run_guard()
        self.assertEqual(self.count(), vb.count_text(0))

    def test_rescue_not_counted(self):
        self.boot_as(root="rescue")
        self.run_guard()
        self.assertEqual(self.count(), vb.count_text(0))

    def test_formats_agree(self):
        """What the shell writes must be byte for byte what vip-boot writes."""
        self.run_guard()
        self.assertEqual(self.count(), vb.count_text(1))
        with open(f"{self.bootsel}/vipboot/reason") as f:
            self.assertEqual(len(f.read()), vb.REASON_W)

    def test_foreign_file_left_alone(self):
        with open(f"{self.bootsel}/vipboot/count", "w") as f:
            f.write("count=1\n")
        r = self.run_guard()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.count(), "count=1\n")
        self.assertIn("not vip-boot's", r.stderr)

    def test_missing_bootsel_never_blocks(self):
        shutil.rmtree(f"{self.bootsel}/vipboot")
        r = self.run_guard()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.reboots_seen(), [])


if __name__ == "__main__":
    unittest.main()
