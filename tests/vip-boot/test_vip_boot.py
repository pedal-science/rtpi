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
        # The partitions, as the image build makes them.
        self.bootsel = r + self.env["BOOTSEL_MOUNT"]
        self.boot = r + self.env["PEDAL_BOOT_MOUNT"]
        self.run_vb("init-bootsel", "--dir", self.bootsel)
        self.run_vb("init-pedal-boot", "--dir", self.boot, "--kernel-root", r, "--release", OLD)
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
