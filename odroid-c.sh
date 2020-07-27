#!/bin/bash
set -e

# This is the HardKernel ODROID C Kali ARM build script - http://hardkernel.com/main/main.php
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com

# Uncomment to activate debug
# debug=true

if [ "$debug" = true ]; then
  exec > >(tee -a -i "${0%.*}.log") 2>&1
  set -x
fi

# Architecture
architecture=${architecture:-"armhf"}
# Generate a random machine name to be used.
machine=$(tr -cd 'A-Za-z0-9' < /dev/urandom | head -c16 ; echo)
# Custom hostname variable
hostname=${2:-kali}
# Custom image file name variable - MUST NOT include .img at the end.
imagename=${3:-kali-linux-$1-odroidc}
# Suite to use, valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
suite=${suite:-"kali-rolling"}
# Free space rootfs in MiB
free_space="300"
# /boot partition in MiB
bootsize="128"
# Select compression, xz or none
compress="xz"
# Choose filesystem format to format ( ext3 or ext4 )
fstype="ext3"
# If you have your own preferred mirrors, set them here.
mirror=${4:-"http://http.kali.org/kali"}
# Gitlab url Kali repository
kaligit="https://gitlab.com/kalilinux"
# Github raw url
githubraw="https://raw.githubusercontent.com"

# Check EUID=0 you can run any binary as root.
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# Pass version number
if [[ $# -eq 0 ]] ; then
  echo "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali"
  exit 0
fi

# Check exist bsp directory.
if [ ! -e "bsp" ]; then
  echo "Error: missing bsp directory structure"
  echo "Please clone the full repository ${kaligit}/build-scripts/kali-arm"
  exit 255
fi

# Current directory
current_dir="$(pwd)"
# Base directory
basedir=${current_dir}/odroidc-"$1"
# Working directory
work_dir="${basedir}/kali-${architecture}"

# Check directory build
if [ -e "${basedir}" ]; then
  echo "${basedir} directory exists, will not continue"
  exit 1
elif [[ ${current_dir} =~ [[:space:]] ]]; then
  echo "The directory "\"${current_dir}"\" contains whitespace. Not supported."
  exit 1
else
  echo "The basedir thinks it is: ${basedir}"
  mkdir -p ${basedir}
fi

components="main,contrib,non-free"
arm="kali-linux-arm ntpdate"
base="apt-transport-https apt-utils bash-completion console-setup dialog e2fsprogs ifupdown initramfs-tools inxi iw man-db mlocate netcat-traditional net-tools parted pciutils psmisc rfkill screen tmux unrar usbutils vim wget whiptail zerofree"
desktop="kali-desktop-xfce kali-root-login xserver-xorg-video-fbdev xfonts-terminus xinput"
tools="kali-linux-default"
services="apache2 atftpd"
extras="alsa-utils bc bison bluez bluez-firmware fbset kali-linux-core libnss-systemd libssl-dev triggerhappy"

packages="${arm} ${base} ${services}"

# Automatic configuration to use an http proxy, such as apt-cacher-ng.
# You can turn off automatic settings by uncommenting apt_cacher=off.
# apt_cacher=off
# By default the proxy settings are local, but you can define an external proxy.
# proxy_url="http://external.intranet.local"
apt_cacher=${apt_cacher:-"$(lsof -i :3142|cut -d ' ' -f3 | uniq | sed '/^\s*$/d')"}
if [ -n "$proxy_url" ]; then
  export http_proxy=$proxy_url
elif [ "$apt_cacher" = "apt-cacher-ng" ] ; then
  if [ -z "$proxy_url" ]; then
    proxy_url=${proxy_url:-"http://127.0.0.1:3142/"}
    export http_proxy=$proxy_url
  fi
fi

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
debootstrap --foreign --keyring=/usr/share/keyrings/kali-archive-keyring.gpg --include=kali-archive-keyring \
  --components=${components} --arch ${architecture} ${suite} ${work_dir} http://http.kali.org/kali

# systemd-nspawn enviroment
systemd-nspawn_exec(){
  qemu_bin=/usr/bin/qemu-arm-static
  LANG=C systemd-nspawn -q --bind-ro ${qemu_bin} -M ${machine} -D ${work_dir} "$@"
}

# debootstrap second stage
systemd-nspawn_exec /debootstrap/debootstrap --second-stage

cat << EOF > ${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Set hostname
echo "${hostname}" > ${work_dir}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > ${work_dir}/etc/hosts
127.0.0.1       ${hostname}    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Disable IPv6
cat << EOF > ${work_dir}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
EOF

cat << EOF > ${work_dir}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# DNS server
echo "nameserver 8.8.8.8" > ${work_dir}/etc/resolv.conf

# Copy directory bsp into build dir.
cp -rp bsp ${work_dir}

export MALLOC_CHECK_=0 # workaround for LP: #520465

# Enable the use of http proxy in third-stage in case it is enabled.
if [ -n "$proxy_url" ]; then
  echo "Acquire::http { Proxy \"$proxy_url\" };" > ${work_dir}/etc/apt/apt.conf.d/66proxy
fi

# Third stage
cat << EOF >  ${work_dir}/third-stage
#!/bin/bash -e
export DEBIAN_FRONTEND=noninteractive
export RUNLEVEL=1
ln -sf /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

apt-get update

apt-get update
apt-get -y install binutils ca-certificates console-common git initramfs-tools less locales nano u-boot-tools

# Create kali user with kali password... but first, we need to manually make some groups because they don't yet exist...
# This mirrors what we have on a pre-installed VM, until the script works properly to allow end users to set up their own... user.
# However we leave off floppy, because who a) still uses them, and b) attaches them to an SBC!?
# And since a lot of these have serial devices of some sort, dialout is added as well.
# scanner, lpadmin and bluetooth have to be added manually because they don't
# yet exist in /etc/group at this point.
groupadd -r -g 118 bluetooth
groupadd -r -g 113 lpadmin
groupadd -r -g 122 scanner
groupadd -g 1000 kali

useradd -m -u 1000 -g 1000 -G sudo,audio,bluetooth,cdrom,dialout,dip,lpadmin,netdev,plugdev,scanner,video,kali -s /bin/bash kali
echo "kali:kali" | chpasswd

aptops="--allow-change-held-packages -o dpkg::options::=--force-confnew"

# This looks weird, but we do it twice because every so often, there's a failure to download from the mirror
# So to workaround it, we attempt to install them twice.
apt-get install -y \$aptops ${packages} || apt-get --yes --fix-broken install
apt-get install -y \$aptops ${packages} || apt-get --yes --fix-broken install
apt-get install -y \$aptops ${desktop} ${extras} ${tools} || apt-get --yes --fix-broken install
apt-get install -y \$aptops ${desktop} ${extras} ${tools} || apt-get --yes --fix-broken install
apt-get install -y \$aptops --autoremove systemd-timesyncd || apt-get --yes --fix-broken install
apt-get dist-upgrade -y \$aptops

apt-get -y --allow-change-held-packages --purge autoremove

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

# Copy all services
install -m644 /bsp/services/all/*.service /etc/systemd/system/
install -m644 /bsp/services/odroid-c2/*.service /etc/systemd/system/

# Create symlink to enable the service...
ln -sf /etc/systemd/system/amlogic.service /etc/systemd/system/multi-user.target.wants/amlogic.service

# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot.
systemctl enable smi-hack

# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys
# Enable sshd
systemctl enable ssh

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Copy bashrc
cp  /etc/skel/.bashrc /root/.bashrc

# Set a REGDOMAIN.  This needs to be done or wireless doesn't work correctly on the RPi 3B+
sed -i -e 's/REGDOM.*/REGDOMAIN=00/g' /etc/default/crda

# Enable login over serial
echo 'T1:12345:respawn:/sbin/agetty 115200 ttyS0 vt100' >> /etc/inittab

# Try and make the console a bit nicer
# Set the terminus font for a bit nicer display.
sed -i -e 's/FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup
sed -i -e 's/FONTSIZE=.*/FONTSIZE="6x12"/' /etc/default/console-setup

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/usr/lib/systemd/system/networking.service"

rm -f /usr/sbin/policy-rc.d
unlink /usr/sbin/invoke-rc.d
EOF

# Run third stage
chmod 755 ${work_dir}/third-stage
systemd-nspawn_exec /third-stage

# Clean system
systemd-nspawn_exec << EOF
rm -f /0
rm -rf /bsp
fc-cache -frs
rm -rf /tmp/*
rm -rf /etc/*-
rm -rf /hs_err*
rm -rf /userland
rm -rf /opt/vc/src
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/dpkg/*-old
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/debconf/*.data-old
history -c
EOF
#Clear all logs
for logs in `find $work_dir/var/log -type f`; do > $logs; done

# Disable the use of http proxy in case it is enabled.
if [ -n "$proxy_url" ]; then
  unset http_proxy
  rm -rf ${work_dir}/etc/apt/apt.conf.d/66proxy
fi

# Mirror replacement
if [ ! -z "${@:5}" ]; then
  [ $suite != kali-rolling ] || suite=kali-rolling
  mirror=${@:5}
fi

# Define sources.list
cat << EOF > ${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Clone an older cross compiler to build the older u-boot/kernel.
cd "${basedir}"
git clone --depth 1 https://gitlab.com/kalilinux/packages/gcc-arm-linux-gnueabihf-4-7.git gcc-arm-linux-gnueabihf-4.7

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
git clone --depth 1 https://github.com/hardkernel/linux -b odroidc-3.10.y ${work_dir}/usr/src/kernel
cd ${work_dir}/usr/src/kernel
git rev-parse HEAD > ${work_dir}/usr/src/kernel-at-commit
touch .scmversion
export ARCH=arm
# NOTE: 3.8 now works with a 4.8 compiler, 3.4 does not!
export CROSS_COMPILE="${basedir}"/gcc-arm-linux-gnueabihf-4.7/bin/arm-linux-gnueabihf-
patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/mac80211-backports.patch
patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/0001-wireless-carl9170-Enable-sniffer-mode-promisc-flag-t.patch
make odroidc_defconfig
cp .config ../odroidc.config
make -j $(grep -c processor /proc/cpuinfo)
make uImage
make modules_install INSTALL_MOD_PATH=${work_dir}
cp arch/arm/boot/uImage ${work_dir}/boot/
cp arch/arm/boot/dts/meson8b_odroidc.dtb ${work_dir}/boot/
make mrproper
cp ../odroidc.config .config
cd "${basedir}"

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${work_dir}/lib/modules/)
cd ${work_dir}/lib/modules/${kernver}
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source
cd "${basedir}"

# Create a boot.ini file with possible options if people want to change them.
cat << EOF > ${work_dir}/boot/boot.ini
ODROIDC-UBOOT-CONFIG

# Possible screen resolutions
# Uncomment only a single Line! The line with setenv written.
# At least one mode must be selected.

# setenv m "vga"                # 640x480
# setenv m "480p"               # 720x480
# setenv m "576p"               # 720x576
# setenv m "800x480p60hz"       # 800x480
# setenv m "800x600p60hz"       # 800x600
# setenv m "1024x600p60hz"      # 1024x600
# setenv m "1024x768p60hz"      # 1024x768
# setenv m "1360x768p60hz"      # 1360x768
# setenv m "1440x900p60hz"      # 1440x900
# setenv m "1600x900p60hz"      # 1600x900
# setenv m "1680x1050p60hz"     # 1680x1050
# setenv m "720p"               # 720p 1280x720
# setenv m "800p"               # 1280x800
# setenv m "sxga"               # 1280x1024
# setenv m "1080i50hz"          # 1080I@50Hz
# setenv m "1080p24hz"          # 1080P@24Hz
# setenv m "1080p50hz"          # 1080P@50Hz
setenv m "1080p"                # 1080P@60Hz
# setenv m "1920x1200"          # 1920x1200

# HDMI DVI Mode Configuration
setenv vout_mode "hdmi"
# setenv vout_mode "dvi"
# setenv vout_mode "vga"

# HDMI BPP Mode
setenv m_bpp "32"
# setenv m_bpp "24"
# setenv m_bpp "16"

# HDMI Hotplug Force (HPD)
# 1 = Enables HOTPlug Detection
# 0 = Disables HOTPlug Detection and force the connected status
setenv hpd "0"

# CEC Enable/Disable (Requires Hardware Modification)
# 1 = Enables HDMI CEC
# 0 = Disables HDMI CEC
setenv cec "0"

# PCM5102 I2S Audio DAC
# PCM5102 is an I2S Audio Dac Addon board for ODROID-C1+
# Uncomment the line below to __ENABLE__ support for this Addon board.
# setenv enabledac "enabledac"

# UHS Card Configuration
# Uncomment the line below to __DISABLE__ UHS-1 MicroSD support
# This might break boot for some brand models of cards.
setenv disableuhs "disableuhs"


# Disable VPU (Video decoding engine, Saves RAM!!!)
# 0 = disabled
# 1 = enabled
setenv vpu "1"

# Disable HDMI Output (Again, saves ram!)
# 0 = disabled
# 1 = enabled
setenv hdmioutput "1"

# Default Console Device Setting
# setenv condev "console=ttyS0,115200n8"        # on serial port
# setenv condev "console=tty0"                    # on display (HDMI)
setenv condev "console=tty0 console=ttyS0,115200n8"   # on both



###########################################

if test "\${hpd}" = "0"; then setenv hdmi_hpd "disablehpd=true"; fi
if test "\${cec}" = "1"; then setenv hdmi_cec "hdmitx=cecf"; fi

# Boot Arguments
setenv bootargs "root=/dev/mmcblk0p2 rootfstype=$fstype quiet rootwait rw \${condev} no_console_suspend vdaccfg=0xa000 logo=osd1,loaded,0x7900000,720p,full dmfc=3 cvbsmode=576cvbs hdmimode=\${m} m_bpp=\${m_bpp} vout=\${vout_mode} \${disableuhs} \${hdmi_hpd} \${hdmi_cec} \${enabledac} net.ifnames=0"

# Booting
fatload mmc 0:1 0x21000000 uImage
fatload mmc 0:1 0x22000000 uInitrd
fatload mmc 0:1 0x21800000 meson8b_odroidc.dtb
fdt addr 21800000

if test "\${vpu}" = "0"; then fdt rm /mesonstream; fdt rm /vdec; fdt rm /ppmgr; fi

if test "\${hdmioutput}" = "0"; then fdt rm /mesonfb; fi

# If you're going to use an initrd, uncomment this line and comment out the bottom line.
#bootm 0x21000000 0x22000000 0x21800000"
bootm 0x21000000 - 0x21800000"
EOF

cat << EOF > ${work_dir}/usr/bin/amlogic.sh
#!/bin/sh

for x in \$(cat /proc/cmdline); do
    case \${x} in
        m_bpp=*) export bpp=\${x#*=} ;;
        hdmimode=*) export mode=\${x#*=} ;;
    esac
done

HPD_STATE=/sys/class/amhdmitx/amhdmitx0/hpd_state
DISP_CAP=/sys/class/amhdmitx/amhdmitx0/disp_cap
DISP_MODE=/sys/class/display/mode

hdmi=\`cat \$HPD_STATE\`
if [ \$hdmi -eq 1 ]; then
    echo \$mode > \$DISP_MODE
fi

outputmode=\$mode

common_display_setup() {
    fbset -fb /dev/fb1 -g 32 32 32 32 32
    echo \$outputmode > /sys/class/display/mode
    echo 0 > /sys/class/ppmgr/ppscaler
    echo 0 > /sys/class/graphics/fb0/free_scale
    echo 1 > /sys/class/graphics/fb0/freescale_mode

    case \$outputmode in
            800x480*) M="0 0 799 479" ;;
            vga*)  M="0 0 639 749" ;;
            800x600p60*) M="0 0 799 599" ;;
            1024x600p60h*) M="0 0 1023 599" ;;
            1024x768p60h*) M="0 0 1023 767" ;;
            sxga*) M="0 0 1279 1023" ;;
            1440x900p60*) M="0 0 1439 899" ;;
            480*) M="0 0 719 479" ;;
            576*) M="0 0 719 575" ;;
            720*) M="0 0 1279 719" ;;
            800*) M="0 0 1279 799" ;;
            1080*) M="0 0 1919 1079" ;;
            1920x1200*) M="0 0 1919 1199" ;;
            1680x1050p60*) M="0 0 1679 1049" ;;
        1360x768p60*) M="0 0 1359 767" ;;
        1366x768p60*) M="0 0 1365 767" ;;
        1600x900p60*) M="0 0 1599 899" ;;
    esac

    echo \$M > /sys/class/graphics/fb0/free_scale_axis
    echo \$M > /sys/class/graphics/fb0/window_axis
    echo 0x10001 > /sys/class/graphics/fb0/free_scale
    echo 0 > /sys/class/graphics/fb1/free_scale
}

case \$mode in
    800x480*)           fbset -fb /dev/fb0 -g 800 480 800 960 \$bpp;     common_display_setup ;;
    vga*)               fbset -fb /dev/fb0 -g 640 480 640 960 \$bpp;     common_display_setup ;;
    480*)               fbset -fb /dev/fb0 -g 720 480 720 960 \$bpp;     common_display_setup ;;
    800x600p60*)        fbset -fb /dev/fb0 -g 800 600 800 1200 \$bpp;    common_display_setup ;;
    576*)               fbset -fb /dev/fb0 -g 720 576 720 1152 \$bpp;    common_display_setup ;;
    1024x600p60h*)      fbset -fb /dev/fb0 -g 1024 600 1024 1200 \$bpp;  common_display_setup ;;
    1024x768p60h*)      fbset -fb /dev/fb0 -g 1024 768 1024 1536 \$bpp;  common_display_setup ;;
    720*)               fbset -fb /dev/fb0 -g 1280 720 1280 1440 \$bpp;  common_display_setup ;;
    800*)               fbset -fb /dev/fb0 -g 1280 800 1280 1600 \$bpp;  common_display_setup ;;
    sxga*)              fbset -fb /dev/fb0 -g 1280 1024 1280 2048 \$bpp; common_display_setup ;;
    1440x900p60*)       fbset -fb /dev/fb0 -g 1440 900 1440 1800 \$bpp;  common_display_setup ;;
    1080*)              fbset -fb /dev/fb0 -g 1920 1080 1920 2160 \$bpp; common_display_setup ;;
    1920x1200*)         fbset -fb /dev/fb0 -g 1920 1200 1920 2400 \$bpp; common_display_setup ;;
    1360x768p60*)       fbset -fb /dev/fb0 -g 1360 768 1360 1536 \$bpp;  common_display_setup ;;
    1366x768p60*)       fbset -fb /dev/fb0 -g 1366 768 1366 1536 \$bpp;  common_display_setup ;;
    1600x900p60*)       fbset -fb /dev/fb0 -g 1600 900 1600 1800 \$bpp;  common_display_setup ;;
    1680x1050p60*)      fbset -fb /dev/fb0 -g 1680 1050 1680 2100 \$bpp; common_display_setup ;;
esac


# Console unblack
echo 0 > /sys/class/graphics/fb0/blank
echo 0 > /sys/class/graphics/fb1/blank


# Network Tweaks. Thanks to mlinuxguy
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
echo 2048 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt
echo 7 > /sys/class/net/eth0/queues/rx-0/rps_cpus
echo 7 > /sys/class/net/eth0/queues/tx-0/xps_cpus

# Move IRQ's of ethernet to CPU1/2
echo 1,2 > /proc/irq/40/smp_affinity_list
EOF
chmod 755 ${work_dir}/usr/bin/amlogic.sh

cat << EOF > ${work_dir}/etc/sysctl.d/99-c1-network.conf
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 514400
net.core.wmem_default = 514400
net.ipv4.tcp_rmem = 10240 87380 26214400
net.ipv4.tcp_wmem = 10240 87380 26214400
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.core.optmem_max = 65535
net.core.netdev_max_backlog = 5000
EOF

cd ${current_dir}

# Calculate the space to create the image.
root_size=$(du -s -B1 ${work_dir} --exclude=${work_dir}/boot | cut -f1)
root_extra=$((${root_size}/1024/1000*5*1024/5))
raw_size=$(($((${free_space}*1024))+${root_extra}+$((${bootsize}*1024))+4096))

# Create the disk and partition it
echo "Creating image file ${imagename}.img"
fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si) ${current_dir}/${imagename}.img
parted -s ${current_dir}/${imagename}.img mklabel msdos
parted -s ${current_dir}/${imagename}.img mkpart primary fat32 4MiB ${bootsize}MiB
parted -s -a minimal ${current_dir}/${imagename}.img mkpart primary $fstype ${bootsize}MiB 100%

# Set the partition variables
loopdevice=`losetup -f --show ${current_dir}/${imagename}.img`
device=`kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat -n BOOT ${bootp}
if [[ $fstype == ext4 ]]; then
  features="-O ^64bit,^metadata_csum"
elif [[ $fstype == ext3 ]]; then
  features="-O ^64bit"
fi
mkfs $features -t $fstype -L ROOTFS ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root
mkdir -p "${basedir}"/root/boot
mount ${bootp} "${basedir}"/root/boot

# We do this down here to get rid of the build system's resolv.conf after running through the build.
cat << EOF > ${work_dir}/etc/resolv.conf
nameserver 8.8.8.8
EOF

# Create an fstab so that we don't mount / read-only.
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               $fstype    errors=remount-ro 0       1" >> ${work_dir}/etc/fstab

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${work_dir}/ ${basedir}/root/

# Unmount partitions
sync
umount ${bootp}
umount ${rootp}
kpartx -dv ${loopdevice}

cd ${basedir}
# Build the latest u-boot bootloader, and then use the Hardkernel script to fuse
# it to the image.  This is required because of a requirement that the
# bootloader be signed.
git clone --depth 1 https://github.com/hardkernel/u-boot -b odroidc-v2011.03
cd ${basedir}/u-boot
# https://code.google.com/p/chromium/issues/detail?id=213120
sed -i -e "s/soft-float/float-abi=hard -mfpu=vfpv3/g" \
    arch/arm/cpu/armv7/config.mk
make CROSS_COMPILE="${basedir}"/gcc-arm-linux-gnueabihf-4.7/bin/arm-linux-gnueabihf- odroidc_config
make CROSS_COMPILE="${basedir}"/gcc-arm-linux-gnueabihf-4.7/bin/arm-linux-gnueabihf- -j $(grep -c processor /proc/cpuinfo)

cd sd_fuse
sh sd_fusing.sh ${loopdevice}

cd "${basedir}"

losetup -d ${loopdevice}

# Limite use cpu function
limit_cpu (){
  rand=$(tr -cd 'A-Za-z0-9' < /dev/urandom | head -c4 ; echo) # Randowm name group
  cgcreate -g cpu:/cpulimit-${rand} # Name of group cpulimit
  cgset -r cpu.shares=800 cpulimit-${rand} # Max 1024
  cgset -r cpu.cfs_quota_us=80000 cpulimit-${rand} # Max 100000
  # Retry command
  local n=1; local max=5; local delay=2
  while true; do
    cgexec -g cpu:cpulimit-${rand} "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo -e "\e[31m Command failed. Attempt $n/$max \033[0m"
        sleep $delay;
      else
        echo "The command has failed after $n attempts."
        break
      fi
    }
  done
}

if [ $compress = xz ]; then
  if [ $(arch) == 'x86_64' ]; then
    echo "Compressing ${imagename}.img"
    limit_cpu pixz -p 2 ${current_dir}/${imagename}.img # -p Nº cpu cores use
    chmod 644 ${current_dir}/${imagename}.img.xz
  fi
else
  chmod 644 ${current_dir}/${imagename}.img
fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Clean up the build system"
rm -rf "${basedir}"
