> **dagu 对照（不是本页设备）：** 这是 11" **elish** 的 pmOS wiki 摘录。自造 boot 是 header **v0** + `append_dtb`，不是原厂 v2：[elish-pmos-boot-format.md](elish-pmos-boot-format.md)。12.4" dagu **不要**照抄 `fastboot erase dtbo_b` 去刷 `dtbo-empty.img`（合法空表、`count=0`）。那会让 HyperOS ABL Load Error，约 6 秒回 fastboot。机制：[dagu-dtbo-abl.md](dagu-dtbo-abl.md)。

Xiaomi Mi Pad 5 Pro (xiaomi-elish)
Page
Read
View source
View history

Tools
Appearance hide
Text

Small

Standard

Large
Width

Standard

Wide
Xiaomi Mi Pad 5 Pro
Xiaomi Pad 5 Pro running phosh ui with mainline kernel.
Xiaomi Pad 5 Pro running phosh ui with mainline kernel.
Manufacturer	Xiaomi
Name	Mi Pad 5 Pro
Codename	xiaomi-elish
Released	2021
Type	tablet
Hardware
Chipset	Qualcomm Snapdragon 870 (SM8250-AC)
CPU	Octa-core (1x3.2 GHz Kryo 585
3x2.42 GHz Kryo 585
4x1.80 GHz Kryo 585)
GPU	Adreno 650
Display	2560x1600 120HZ IPS LCD
Storage	128/256 GiB
Memory	6/8 GiB
Architecture	aarch64
Software
Android 11 (MIUI 12.5)
Android 13 (MIUI 14.0)
postmarketOS
Category	testing
yes
6.17.0

see Unixbench page on wiki
0.0
Device package	device-xiaomi-elish
Kernel package	linux-postmarketos-qcom-sm8250
Features
Works
Works
Works
Partial
Works
Touchscreen
Works
Works
Stylus
Works
Multimedia
3D Acceleration
Works
Partial
Camera
Broken
Camera Flash
Works
Connectivity
WiFi
Works
Bluetooth
Works
GPS
Broken
Miscellaneous
Untested
Works
Sensors
Works
Works
Broken
(See also Xiaomi Mi Pad 5 Pro 5G (xiaomi-enuma) page for a 5G variant of the same device)

Contributors
Jianhua
Users owning this device
CalcProgrammer1
Jianhua (Notes: mainlining in progress)
How to enter flash mode
You have to press Power + Volume Down to enter the bootloader.

Backup
This section is Optional

Backup super partiton, either by using Magisk (need root) or without root using a recovery program such as TWRP or Orange Fox.

Method 1: Magisk
Use Magisk:

 $ adb shell
 $ su
 # dd if=/dev/block/by-name/super of=/sdcard/super.img
 # exit
 $ exit
 $ adb pull /sdcard/super.img
Method 2: Orange Fox Recovery Project
Use Orange Fox Recovery Project:

Download and rename "OrangeFox-23.07.04-Unofficial-elish.img" to "boot.img"

 $ mv OrangeFox-23.07.04-Unofficial-elish.img boot.img
 $ fastboot boot boot.img
 $ adb shell
 # dd if=/dev/block/by-name/super of=/sdcard/super.img
 # exit
 $ adb pull /sdcard/super.img
Installation
Install pmbootstrap and execute:

 $ pmbootstrap init
 $ pmbootstrap install
Know your panel variant
There are two variants of the Mi Pad 5 Pro with different display panels and touchscreens.

1. BOE panel - msm_drm.dsi_display0=qcom,mdss_dsi_k81_35_02_0b_dual_cphy_video

2. CSOT panel - msm_drm.dsi_display0=qcom,mdss_dsi_k81_42_02_0a_dual_cphy_video


To know your panel variant, get into a terminal with root access (you can use TWRP recovery's terminal as it has root access or rooted android ROM)

1. Run su to make sure you have root access

2. Run cat /proc/cmdline. Output would be similar to:

console=null  pmos_boot_uuid=0cc94667-2fa8-45a3-ab73-eee557029e7f pmos_root_uuid=69b5c6a3-7def-4390-88fc-46cd1d4bbeb0 pmos_rootfsopts=defaults androidboot.verifiedbootstate=orange androidboot.keymaster=1 androidboot.vbmeta.device=PARTUUID=cd1cfbb7-7a7f-9f61-e1dc-df3128bdbcc9 androidboot.vbmeta.avb_version=1.0 androidboot.vbmeta.device_state=unlocked androidboot.vbmeta.hash_alg=sha256 androidboot.vbmeta.size=7168 androidboot.vbmeta.digest=29a61793c8edf6ef682622256d98221923a488635c819f3554929ad247362ea2 androidboot.vbmeta.invalidate_on_error=yes androidboot.veritymode=enforcing androidboot.bootdevice=1d84000.ufshc androidboot.fstab_suffix=default androidboot.boot_devices=soc/1d84000.ufshc androidboot.serialno=<elish-serial> androidboot.secureboot=1 androidboot.hwversion=C.9.0 androidboot.cpuid=<cpuid> androidboot.hwc=CN androidboot.hwlevel=MP androidboot.baseband=apq msm_drm.dsi_display0=qcom,mdss_dsi_k81_42_02_0a_dual_cphy_video: androidboot.oled_wp=7c7a5d androidboot.slot_suffix=_b rootwait ro init=/init androidboot.ramdump=disable block2mtd.block2mtd=/dev/block/sda15,2097152 mtdoops.mtddev=0 mtdoops.record_size=2097152 mtdoops.dump_oops=0 printk.always_kmsg_dump=1 androidboot.dp=0x0 androidboot.cert=M2105K81AC
4. Note the value of msm_drm.dsi_display0. In the example above, it's qcom,mdss_dsi_k81_42_02_0a_dual_cphy_video, i.e CSOT panel variant. For BOE panel variant, it would be qcom,mdss_dsi_k81_35_02_0b_dual_cphy_video

During pmbootstrap init, select the kernel variant by choosing either boe or csot based on the output from above.

There are multiple ways to flash rootfs:
Before installing rootfs, please erase dtbo_b (dtbo_a reserved for android)
$ fastboot erase dtbo_b
# dagu：这是「擦分区、无 magic」，不是刷 dtbo-empty.img。见 dagu-dtbo-abl.md。
1.Flash rootfs to the userdata partition:
Flashing the rootfs to userdata does not allow for dual boot and will wipe all your Android user data
This method gives you the most available disk space for postmarketOS
$ pmbootstrap flasher flash_rootfs --partition userdata
$ pmbootstrap flasher flash_kernel --partition boot_b
$ fastboot set_active b
2.Flash rootfs to the super partition:
This method does not erase your Android user data
The super partition is rather limited in size
 $ pmbootstrap flasher flash_rootfs --partition super
 $ pmbootstrap flasher flash_kernel --partition boot_b
 $ fastboot set_active b
3.Use fastboot to flash rootfs to system_b partition (dual boot):
 $ fastboot set_active a
 $ fastboot reboot fastboot
 $ pmbootstrap flasher flash_rootfs --partition system_b
 $ pmbootstrap flasher flash_kernel --partition boot_b
 $ fastboot reboot bootloader
 $ fastboot set_active b
SSH into the device (Full instructions):

 $ ssh user@172.16.42.1
Issues
Charging
1. Fast charging (bq25970) only works with offical xiaomi charger. You can check it by the command:

$ sudo cat /sys/kernel/debug/usb/tcpm-c440000.spmi:pmic@2:typec@1500/log
[    0.585986] Setting usb_comm capable false
[    0.586038] Setting voltage/current limit 0 mV 0 mA
[    0.586041] polarity 0
[    0.586045] Requesting mux state 0, usb-role 0, orientation 0
[    0.586091] state change INVALID_STATE -> SRC_UNATTACHED [rev1 NONE_AMS]
[    0.586125] CC1: 0 -> 0, CC2: 0 -> 5 [state SRC_UNATTACHED, polarity 0, connected]
[    0.586129] state change SRC_UNATTACHED -> PORT_RESET [rev1 NONE_AMS]
[    0.586131] c440000.spmi:pmic@2:typec@1500: registered
[    0.586735] Setting usb_comm capable false
[    0.586774] Setting voltage/current limit 0 mV 0 mA
[    0.586778] polarity 0
[    0.586778] Requesting mux state 0, usb-role 0, orientation 0
[    0.586798] cc:=0
[    0.586821] pending state change PORT_RESET -> PORT_RESET_WAIT_OFF @ 100 ms [rev1 NONE_AMS]
[    0.687519] state change PORT_RESET -> PORT_RESET_WAIT_OFF [delayed 100 ms]
[    0.687527] pending state change PORT_RESET_WAIT_OFF -> SRC_UNATTACHED @ 920 ms [rev1 NONE_AMS]
[    1.607559] state change PORT_RESET_WAIT_OFF -> SRC_UNATTACHED [delayed 920 ms]
[    1.607570] Start toggling
[    1.607618] state change SRC_UNATTACHED -> TOGGLING [rev1 NONE_AMS]
[    1.734119] CC1: 0 -> 0, CC2: 5 -> 5 [state TOGGLING, polarity 0, connected]
[    1.734128] state change TOGGLING -> SNK_ATTACH_WAIT [rev1 NONE_AMS]
[    1.734153] CC1: 0 -> 0, CC2: 5 -> 5 [state SNK_ATTACH_WAIT, polarity 0, connected]
[    1.734157] state change SNK_ATTACH_WAIT -> SNK_ATTACH_WAIT [rev1 NONE_AMS]
[    1.734160] pending state change SNK_ATTACH_WAIT -> SNK_DEBOUNCED @ 200 ms [rev1 NONE_AMS]
[    1.934185] state change SNK_ATTACH_WAIT -> SNK_DEBOUNCED [delayed 200 ms]
[    1.934192] state change SNK_DEBOUNCED -> SNK_ATTACHED [rev1 NONE_AMS]
[    1.934195] polarity 1
[    1.934198] Requesting mux state 1, usb-role 2, orientation 2
[    1.934264] state change SNK_ATTACHED -> SNK_STARTUP [rev1 NONE_AMS]
[    1.934280] state change SNK_STARTUP -> SNK_DISCOVERY [rev3 NONE_AMS]
[    1.934283] Setting voltage/current limit 5000 mV 3000 mA
[    1.934293] vbus=0 charge:=1
[    1.934296] state change SNK_DISCOVERY -> SNK_WAIT_CAPABILITIES [rev3 NONE_AMS]
[    1.934316] pending state change SNK_WAIT_CAPABILITIES -> SNK_SOFT_RESET @ 310 ms [rev3 NONE_AMS]
[    2.244353] state change SNK_WAIT_CAPABILITIES -> SNK_SOFT_RESET [delayed 310 ms]
[    2.244358] AMS SOFT_RESET_AMS start
[    2.244361] state change SNK_SOFT_RESET -> AMS_START [rev3 SOFT_RESET_AMS]
[    2.244368] state change AMS_START -> SOFT_RESET_SEND [rev3 SOFT_RESET_AMS]
[    2.244373] PD TX, header: 0x8d
[    2.245664] PD TX complete, status: 0
[    2.245716] pending state change SOFT_RESET_SEND -> HARD_RESET_SEND @ 60 ms [rev3 SOFT_RESET_AMS]
[    2.250202] PD RX, header: 0x1a3 [1]
[    2.250208] AMS SOFT_RESET_AMS finished
[    2.250210] state change SOFT_RESET_SEND -> SNK_WAIT_CAPABILITIES [rev3 NONE_AMS]
[    2.250232] pending state change SNK_WAIT_CAPABILITIES -> SNK_WAIT_CAPABILITIES_TIMEOUT @ 310 ms [rev3 NONE_AMS]
[    2.254532] PD RX, header: 0x43a1 [1]
[    2.254538]  PDO 0: type 0, 5000 mV, 3000 mA [DE]
[    2.254541]  PDO 1: type 0, 9000 mV, 3000 mA []
[    2.254544]  PDO 2: type 0, 15000 mV, 3000 mA []
[    2.254546]  PDO 3: type 0, 20000 mV, 3250 mA []
[    2.254685] state change SNK_WAIT_CAPABILITIES -> SNK_NEGOTIATE_CAPABILITIES [rev3 POWER_NEGOTIATION]
[    2.254690] Setting usb_comm capable false
[    2.254704] cc=0 cc1=0 cc2=5 vbus=0 vconn=sink polarity=1
[    2.254707] Requesting PDO 1: 9000 mV, 3000 mA
[    2.254710] PD TX, header: 0x1282
[    2.256140] PD TX complete, status: 0
[    2.256155] pending state change SNK_NEGOTIATE_CAPABILITIES -> HARD_RESET_SEND @ 60 ms [rev3 POWER_NEGOTIATION]
[    2.260463] PD RX, header: 0x5a3 [1]
[    2.260466] state change SNK_NEGOTIATE_CAPABILITIES -> SNK_TRANSITION_SINK [rev3 POWER_NEGOTIATION]
[    2.260470] Setting standby current 5000 mV @ 500 mA
[    2.260474] Setting voltage/current limit 5000 mV 500 mA
[    2.260481] pending state change SNK_TRANSITION_SINK -> HARD_RESET_SEND @ 500 ms [rev3 POWER_NEGOTIATION]
[    2.370625] PD RX, header: 0x7a6 [1]
[    2.370630] Setting voltage/current limit 9000 mV 3000 mA
[    2.370643] state change SNK_TRANSITION_SINK -> SNK_READY [rev3 POWER_NEGOTIATION]
[    2.370742] AMS POWER_NEGOTIATION finished
[    2.370749] AMS DISCOVER_IDENTITY start
[    2.370752] PD TX, header: 0x148f
[    2.372177] PD TX complete, status: 0
[    2.374836] PD RX, header: 0x19af [1]
[    2.374845] Rx VDM cmd 0xff00a081 type 2 cmd 1 len 1
[    2.374853] AMS DISCOVER_IDENTITY finished
[ 1035.827371] VBUS off
[ 1035.827375] state change SNK_READY -> SNK_UNATTACHED [rev3 NONE_AMS]
[ 1035.827379] VBUS VSAFE0V
[ 1035.827393] CC1: 0 -> 0, CC2: 5 -> 0 [state SNK_UNATTACHED, polarity 1, disconnected]
[ 1035.827580] Start toggling
[ 1037.704831] VBUS on
[ 1037.810098] CC1: 0 -> 0, CC2: 0 -> 5 [state TOGGLING, polarity 0, connected]
[ 1037.810111] state change TOGGLING -> SNK_ATTACH_WAIT [rev3 NONE_AMS]
[ 1037.810142] CC1: 0 -> 0, CC2: 5 -> 5 [state SNK_ATTACH_WAIT, polarity 0, connected]
[ 1037.810148] state change SNK_ATTACH_WAIT -> SNK_ATTACH_WAIT [rev3 NONE_AMS]
[ 1037.810155] pending state change SNK_ATTACH_WAIT -> SNK_DEBOUNCED @ 200 ms [rev3 NONE_AMS]
[ 1037.863381] VBUS off
[ 1037.863385] VBUS VSAFE0V
[ 1037.863399] CC1: 0 -> 0, CC2: 5 -> 0 [state SNK_ATTACH_WAIT, polarity 0, disconnected]
[ 1037.863405] state change SNK_ATTACH_WAIT -> SNK_ATTACH_WAIT [rev3 NONE_AMS]
[ 1037.863410] pending state change SNK_ATTACH_WAIT -> SNK_UNATTACHED @ 20 ms [rev3 NONE_AMS]
[ 1037.884375] state change SNK_ATTACH_WAIT -> SNK_UNATTACHED [delayed 20 ms]
[ 1037.884380] Start toggling
[ 1039.000681] VBUS on
[ 1039.000723] CC1: 0 -> 0, CC2: 0 -> 5 [state TOGGLING, polarity 0, connected]
[ 1039.000734] state change TOGGLING -> SNK_ATTACH_WAIT [rev3 NONE_AMS]
[ 1039.000745] pending state change SNK_ATTACH_WAIT -> SNK_DEBOUNCED @ 200 ms [rev3 NONE_AMS]
[ 1039.002657] CC1: 0 -> 0, CC2: 5 -> 5 [state SNK_ATTACH_WAIT, polarity 0, connected]
[ 1039.201465] state change SNK_ATTACH_WAIT -> SNK_DEBOUNCED [delayed 200 ms]
[ 1039.201472] state change SNK_DEBOUNCED -> SNK_ATTACHED [rev3 NONE_AMS]
[ 1039.201475] polarity 1
[ 1039.201478] Requesting mux state 1, usb-role 2, orientation 2
[ 1039.201557] state change SNK_ATTACHED -> SNK_STARTUP [rev3 NONE_AMS]
[ 1039.201563] state change SNK_STARTUP -> SNK_DISCOVERY [rev3 NONE_AMS]
[ 1039.201564] Setting voltage/current limit 5000 mV 3000 mA
[ 1039.201568] vbus=0 charge:=1
[ 1039.201569] state change SNK_DISCOVERY -> SNK_WAIT_CAPABILITIES [rev3 NONE_AMS]
[ 1039.201583] pending state change SNK_WAIT_CAPABILITIES -> SNK_WAIT_CAPABILITIES_TIMEOUT @ 310 ms [rev3 NONE_AMS]
[ 1039.337473] PD RX, header: 0x41a1 [1]
[ 1039.337482]  PDO 0: type 0, 5000 mV, 3000 mA [DE]
[ 1039.337485]  PDO 1: type 0, 9000 mV, 3000 mA []
[ 1039.337489]  PDO 2: type 0, 15000 mV, 3000 mA []
[ 1039.337491]  PDO 3: type 0, 20000 mV, 3250 mA []
[ 1039.337665] state change SNK_WAIT_CAPABILITIES -> SNK_NEGOTIATE_CAPABILITIES [rev3 POWER_NEGOTIATION]
[ 1039.337672] Setting usb_comm capable false
[ 1039.337680] cc=0 cc1=0 cc2=5 vbus=0 vconn=sink polarity=1
[ 1039.337684] Requesting PDO 1: 9000 mV, 3000 mA
[ 1039.337687] PD TX, header: 0x1082
[ 1039.340305] PD TX complete, status: 0
[ 1039.340605] pending state change SNK_NEGOTIATE_CAPABILITIES -> HARD_RESET_SEND @ 60 ms [rev3 POWER_NEGOTIATION]
[ 1039.348651] PD RX, header: 0x3a3 [1]
[ 1039.348664] state change SNK_NEGOTIATE_CAPABILITIES -> SNK_TRANSITION_SINK [rev3 POWER_NEGOTIATION]
[ 1039.348674] Setting standby current 5000 mV @ 500 mA
[ 1039.348678] Setting voltage/current limit 5000 mV 500 mA
[ 1039.348683] pending state change SNK_TRANSITION_SINK -> HARD_RESET_SEND @ 500 ms [rev3 POWER_NEGOTIATION]
[ 1039.495483] PD RX, header: 0x5a6 [1]
[ 1039.495498] Setting voltage/current limit 9000 mV 3000 mA
[ 1039.495505] state change SNK_TRANSITION_SINK -> SNK_READY [rev3 POWER_NEGOTIATION]
[ 1039.495745] AMS POWER_NEGOTIATION finished
[ 1039.495756] AMS DISCOVER_IDENTITY start
[ 1039.495760] PD TX, header: 0x128f
[ 1039.498705] PD TX complete, status: 0
[ 1039.502227] PD RX, header: 0x17af [1]
[ 1039.502240] Rx VDM cmd 0xff00a081 type 2 cmd 1 len 1
[ 1039.502249] AMS DISCOVER_IDENTITY finished
2. bq25970 only works when battery capacity is over 30%.

3. bq25970 will start after 30 seconds when usb is plugined (hardcode in https://gitlab.postmarketos.org/jianhua/sm8250-mainline/-/blob/6.13.0/drivers/power/supply/bq25970_charger.c#L2086).

you can use some commands to see power charging status.

$ sudo apk add lm-sensors
$ watch sensors tcpm_source_psy_c440000.spmi:pmic@2:typec@1500-isa-0000 bq27z561_0-i2c-0-55 bq27z561_1-i2c-13-55
Audio Quality
The audio quality from the speakers is not great, the high end gets cut off and the sound is muffled. It also clips at high volume. Try changing the PCM source for each speaker from "DSP" to "ASP". This greatly improved the audio quality, but also likely disables the speaker protection that the DSP is doing so exercise caution and don't turn the volume up too high.

$ amixer -c 0 cset name="BLL PCM Source" 0
Do this for BLL, BLH, BRL, BRH, TLL, TLH, TRL, and TRH to switch source for all speakers.

Stereo Speakers
The speakers currently do not operate in stereo. All 8 speakers play the left channel of the audio output and the right channel does not play at all. I've been digging into the kernel driver for the CS35L41 audio codec/amplifier chip used (8 chips, one per speaker) and it seems the kernel driver does not expose an ALSA control for setting the RX channel select register. There is a function called set_channel_map() exposed by the driver, but it does not appear to be called from the SM8250 audio driver and it is not exposed to userspace. Specifically, the register in question is the CS35L41_SP_FRAME_RX_SLOT register, regmap address 0x00004820 in the codec's memory space. The regmap is exposed in the kernel's debugfs at /sys/kernel/debug/regmap/1-0040 for the first codec). The others are 1-0041, 1-0042, 1-0043, 3-0040, 3-0041, 3-0042, and 3-0043. The ones prefixed with a 1 are the right side speakers when the tablet is in landscape orientation with the USB port on the right. I had to build a custom kernel to enable regmap write, see this commit:

https://gitlab.com/CalcProgrammer1/linux-sm8250-mainline/-/commit/db5f1bae052acbf7a24cb2487b1724db0e8672a4

This allows the regmap debugfs interface to be able to write to the registers directly (this is dangerous and is usually disabled for good reason). However, I had a pretty good idea what I wanted to do, simply change the 0x00004820 codec register to see if I could select the right channel's RX slot in the I2S/TDM protocol. The register value defaults to 0x00000100, but only the least significant byte seems to matter. I discovered that the value 0x00 means the left channel is selected and the value 0x02 means the right channel is selected. Therefore, to switch all the speakers on the right hand side of the tablet (in landscape mode with the USB port on the right), you can run:

# echo -n "0x00004820 0x00000002" > /sys/kernel/debug/regmap/1-0040/registers
# echo -n "0x00004820 0x00000002" > /sys/kernel/debug/regmap/1-0041/registers
# echo -n "0x00004820 0x00000002" > /sys/kernel/debug/regmap/1-0042/registers
# echo -n "0x00004820 0x00000002" > /sys/kernel/debug/regmap/1-0043/registers
Then all the speakers on the right will play the right channel and you will have stereo. This could be the basis for a sound-rotation script to allow proper stereo sound in any tablet orientation, but I think we need to modify the CS35L41 driver to expose a proper control rather than depending on this debugfs hack. I'm not sure what the best/proper way to do this is.

Audio Recording
In mainline kernel, it appears that audio recording does not work.

Bluetooth
If Bluetooth adapter does not show in bluetoothctl list, try assigning it an address. Install the bluez-btmgmt package and run:

sudo btmgmt --index 0 public-addr 11:22:33:44:55:66
A better option is to install the bootmac package, but in my experience it needs a small tweak. Add 'sleep 1' as the first line in the mac_bluetooth() function in /usr/bin/bootmac as it seems like the elish Bluetooth chip takes a little extra time to start up.

I opened a bug report on the bootmac GitLab to track this sleep issue:

bootmac#4

Hall Sensors
The tablet has several hall sensors. These are used to detect various things:

GPIO 136: Low when pen is attached to tablet, pointing towards the top (power button)

GPIO 138: Low when pen is attached to tablet, pointing towards the bottom (USB port)

These pen detect sensors may be used to enable the wireless charger for the pen. In the downstream dts (https://github.com/LineageOS/android_kernel_xiaomi_sm8250/blob/lineage-21/arch/arm64/boot/dts/vendor/qcom/elish-sm8250.dtsi#L684) these are used by the IDT P9418 driver, which is the wireless charging IC that charges the pen.

GPIO 110: Low when magnetic flip cover is covering screen

GPIO 121: Not entirely sure, sensor is located in the top left (when the tablet is in landscape with the USB port on the right) but does not activate when my flip cover is installed properly. Dragging a magnet around in that area flips this sensor though

Keyboard
As of 6.11.0 kernel, the pogo pin keyboard works. It registers both a keyboard and a mouse device, which causes a cursor to show on screen.

The keyboard is attached via USB internally, but the keyboard MCU is controlled via several GPIOs according to downstream xiaomi_keyboard.c (https://github.com/LineageOS/android_kernel_xiaomi_sm8250/blob/lineage-21/drivers/input/misc/xiaomi_keyboard/xiaomi_keyboard.c):

GPIO 127 - Switches the power to the keyboard MCU on and off, allowing the keyboard MCU to be shut off while the keyboard is not present
GPIO 141 - Reset GPIO for the keyboard MCU, toggle it to output and back to input to reset the keyboard MCU
GPIO 83 - IRQ GPIO for the keyboard MCU, it looks like this interrupt is activated upon attaching or removing the keyboard and toggles the keyboard connected state, but only when the MCU is powered and not in reset
To toggle off the keyboard you can use the "gpioset" utility in package libgpiod.

Power off keyboard: `# gpioset -c 3 127=0`
Power on keyboard: `# gpioset -c 3 127=1`
Hold keyboard in reset: `# gpioset -c 3 141=0`
Release keyboard from reset: `# gpioset -c 3 141=1`
Looking through the Android implementation, it looks like the Android keyboard service is responsible for enabling the keyboard power. The kernel driver starts with the keyboard powered down and exposes a sysfs entry called `xiaomi_keyboard_conn_status`. Writing "enable_keyboard" to this sysfs entry powers up the keyboard (sets GPIO 127). You can also write "disable_keyboard" to power it down, "reset" to perform a reset using the reset GPIO, or "host_reset" to reset as well as reset the USB host it is attached to. Reading this sysfs entry returns whether the keyboard is connected, which is returned as a simple "0" or "1" string. This value comes from mdata->keyboard_conn_status, which is toggled whenever the GPIO 83 interrupt occurs. What I haven't been able to determine is how it determines whether the keyboard is attached at powerup. I did several experiments powering on the keyboard MCU (toggling GPIO 127) with the keyboard attached and detached, and it appears that no matter whether the keyboard is present, the GPIO 83 interrupt is pulsed 4 times when the keyboard MCU powers up.

After more experimentation, it looks like the state gets corrected whenever the keyboard is attached or removed. On MCU powerup, it always produces 4 interrupts. If you assume that the keyboard starts disconnected (which is the default assumption in the downstream driver), an even number of interrupts will result in the status being unchanged as it starts at 0, then goes 1, 0, 1, 0. I then tried starting with the keyboard connected and disconnecting it, as well as starting with the keyboard disconnected and connecting it.

Connected --> Disconnected: 22 total interrupts (even, so indicates keyboard is disconnected)
Disconnected --> Connected: 19 total interrupts (odd, so indicates keyboard is connected)
I'm not sure it is even possible to tell whether the keyboard is present from powerup. I haven't tested this in Android. Also, it does not look like powering down the keyboard controller (to disconnect its USB devices) is a viable strategy for removing these devices from userspace when the keyboard isn't present because the keyboard MCU has to be on to detect when the keyboard is attached. Maybe we have to disable its USB host or make a custom hid driver that removes its input events when the keyboard is disconnected.

The keyboard device always exposes a mouse device as well as the keyboard, and this mouse device can cause unwanted behavior as the invisible cursor can interact with UI elements while using the touchscreen, it also leaves the cursor onscreen after connecting and disconnecting an actual mouse. To remedy this, create a udev rules file:

~ $ cat /etc/udev/rules.d/10-ignore-xiaomi-pad-mouse.rules 
ACTION=="add|change",KERNEL=="event[0-9]*",ATTRS{name}=="Xiaomi Pad Mouse",ENV{LIBINPUT_IGNORE_DEVICE}="1"
ACTION=="add|change",KERNEL=="event[0-9]*",ATTRS{name}=="Xiaomi Pad",ENV{LIBINPUT_IGNORE_DEVICE}="1"
This prevents the unwanted mouse interfaces from showing up as inputs, but allowing the keyboard to continue operation.

Stylus (Xiaomi Smart Pen)
Pen input is working. The pen position, touch, and pressure inputs are sent by the NVTCapacitivePen device which is a secondary device exposed by the NVTCapacitiveTouchScreen device. When paired with Bluetooth, the pen side buttons send Page Up/Page Down keypress inputs.

The pen charges wirelessly by means of the IDT P9418 charger IC, which has a driver in the downstream kernel that we will need to port to mainline — a work is underway at https://github.com/nik012003/idtp9418-mainline. That driver looks at the hall sensors that detect whether the pen is present to turn on and off the wireless charging. This driver also can read the Bluetooth MAC address from the pen over the wireless charging signal so that the pen may be paired automatically when it is attached to the tablet.

See also
Initial merge request: pmaports!2871 pmaports fork: [1]

Categories: DevicesTabletAarch64XiaomiAndroid
