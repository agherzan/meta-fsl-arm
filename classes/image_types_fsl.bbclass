inherit image_types

IMAGE_BOOTLOADER ?= "u-boot"

# Handle u-boot suffixes
UBOOT_SUFFIX ?= "bin"
UBOOT_PADDING ?= "0"
UBOOT_SUFFIX_SDCARD ?= "${UBOOT_SUFFIX}"

#
# Handles i.MX mxs bootstream generation
#

# IMX Bootlets Linux bootstream
IMAGE_DEPENDS_linux.sb = "elftosb-native imx-bootlets virtual/kernel"
IMAGE_LINK_NAME_linux.sb = ""
IMAGE_CMD_linux.sb () {
	kernel_bin="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.bin`"
	kernel_dtb="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.dtb`"
	linux_bd_file=imx-bootlets-linux.bd-${MACHINE}
	if [ `basename $kernel_bin .bin` = `basename $kernel_dtb .dtb` ]; then
		# When using device tree we build a zImage with the dtb
		# appended on the end of the image
		linux_bd_file=imx-bootlets-linux.bd-dtb-${MACHINE}
		cat $kernel_bin $kernel_dtb \
		    > $kernel_bin-dtb
		rm -f ${KERNEL_IMAGETYPE}-${MACHINE}.bin-dtb
		ln -s $kernel_bin-dtb ${KERNEL_IMAGETYPE}-${MACHINE}.bin-dtb
	fi

	# Ensure the file is generated
	rm -f ${IMAGE_NAME}.linux.sb
	elftosb -z -c $linux_bd_file -o ${IMAGE_NAME}.linux.sb

	# Remove the appended file as it is only used here
	rm -f $kernel_bin-dtb
}


# U-Boot mxsboot generation to SD-Card
UBOOT_SUFFIX_SDCARD_mxs ?= "mxsboot-sdcard"
IMAGE_DEPENDS_uboot.mxsboot-sdcard = "u-boot-mxsboot-native u-boot"
IMAGE_CMD_uboot.mxsboot-sdcard = "mxsboot sd ${DEPLOY_DIR_IMAGE}/u-boot-${MACHINE}.${UBOOT_SUFFIX} \
                                             ${DEPLOY_DIR_IMAGE}/u-boot-${MACHINE}.${UBOOT_SUFFIX_SDCARD}"

# Boot partition volume id
BOOTDD_VOLUME_ID ?= "Boot ${MACHINE}"

# Boot partition size [in KiB]
BOOT_SPACE ?= "20480

# Set alignment to 4MB [in KiB]
IMAGE_ROOTFS_ALIGNMENT = "4096"

IMAGE_DEPENDS_sdcard = "parted-native dosfstools-native mtools-native \
                        virtual/kernel ${IMAGE_BOOTLOADER}"

SDCARD = "${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.rootfs.sdcard"

SDCARD_GENERATION_COMMAND_mxs = "generate_mxs_sdcard"
SDCARD_GENERATION_COMMAND_mx5 = "generate_imx_sdcard"
SDCARD_GENERATION_COMMAND_mx6 = "generate_imx_sdcard"



#
# Create an image that can by written onto a SD card using dd for use
# with i.MX SoC family
#
# External variables needed:
#   ${SDCARD_ROOTFS}    - the rootfs image to incorporate
#   ${IMAGE_BOOTLOADER} - bootloader to use {u-boot, barebox}
#
# The disk layout used is:
#
#    0                      -> IMAGE_ROOTFS_ALIGNMENT         - reserved for bootloader and other data (not partitioned)
#    IMAGE_ROOTFS_ALIGNMENT -> BOOT_SPACE                     - kernel
#    BOOT_SPACE             -> SDIMG_SIZE                     - rootfs
#
#
#                                                     Default Free space = 1.3x
#                                                     Use IMAGE_OVERHEAD_FACTOR to add more space
#                                                     <--------->
#            4MiB              20MiB           SDIMG_ROOTFS
# <-----------------------> <----------> <---------------------->
#  ------------------------ ------------ ------------------------ -------------------------------
# | IMAGE_ROOTFS_ALIGNMENT | BOOT_SPACE | ROOTFS_SIZE            |     IMAGE_ROOTFS_ALIGNMENT    |
#  ------------------------ ------------ ------------------------ -------------------------------
# ^                        ^            ^                        ^                               ^
# |                        |            |                        |                               |
# 0                      4MiB     4MiB + 20MiB       4MiB + 20Mib + SDIMG_ROOTFS   4MiB + 20MiB + SDIMG_ROOTFS + 4MiB
#
generate_imx_sdcard () {
	parted -s ${SDIMG} mklabel msdos
	parted -s ${SDIMG} unit KiB mkpart primary ${IMAGE_ROOTFS_ALIGNMENT} $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT})
	parted -s ${SDIMG} set 1 boot on
	parted -s ${SDIMG} unit KiB mkpart primary $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT}) 100%
	parted ${SDIMG} print

	case "${IMAGE_BOOTLOADER}" in
		imx-bootlets)
		bberror "The imx-bootlets is not supported for i.MX based machines"
		exit 1
		;;
		u-boot)
		dd if=${DEPLOY_DIR_IMAGE}/u-boot-${MACHINE}.${UBOOT_SUFFIX_SDCARD} of=${SDCARD} conv=notrunc seek=2 skip=${UBOOT_PADDING} bs=512
		;;
		barebox)
		dd if=${DEPLOY_DIR_IMAGE}/barebox-${MACHINE}.bin of=${SDCARD} conv=notrunc seek=1 skip=1 bs=512
		dd if=${DEPLOY_DIR_IMAGE}/bareboxenv-${MACHINE}.bin of=${SDCARD} conv=notrunc seek=1 bs=512k
		;;
		*)
		bberror "Unkown IMAGE_BOOTLOADER value"
		exit 1
		;;
	esac

	BOOT_BLOCKS=$(LC_ALL=C parted -s ${SDCARD} unit b print \
	                  | awk '/ 1 / { print substr($4, 1, length($4 -1)) / 1024 }')
	mkfs.vfat -n "${BOOTDD_VOLUME_ID}" -S 512 -C ${WORKDIR}/boot.img $BOOT_BLOCKS
	mcopy -i ${WORKDIR}/boot.img -s ${DEPLOY_DIR_IMAGE}/uImage-${MACHINE}.bin ::/uImage
	if [ -e "${KERNEL_IMAGETYPE}-${MACHINE}.dtb" ]; then
		kernel_bin="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.bin`"
		kernel_dtb="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.dtb`"
		if [ `basename $kernel_bin .bin` = `basename $kernel_dtb .dtb` ]; then
			mcopy -i ${WORKDIR}/boot.img -s ${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE}-${MACHINE}.dtb ::/machine.dtb
		fi
	fi

	dd if=${WORKDIR}/boot.img of=${SDCARD} conv=notrunc seek=1 bs=$(expr ${IMAGE_ROOTFS_ALIGNMENT} \* 1024)
	dd if=${SDCARD_ROOTFS} of=${SDCARD} conv=notrunc seek=1 bs=$(expr 1024 \* ${BOOT_SPACE_ALIGNED} + ${IMAGE_ROOTFS_ALIGNMENT} \* 1024)
}

#
# Create an image that can by written onto a SD card using dd for use
# with i.MXS SoC family
#
# External variables needed:
#   ${SDCARD_ROOTFS}    - the rootfs image to incorporate
#   ${IMAGE_BOOTLOADER} - bootloader to use {imx-bootlets, u-boot}
#
generate_mxs_sdcard () {
	# Create partition table
	parted -s ${SDCARD} mklabel msdos

	case "${IMAGE_BOOTLOADER}" in
		imx-bootlets)
		# The disk layout used is:
		#
		#    0                      -> IMAGE_ROOTFS_ALIGNMENT         - reserved for bootloader and other data (not partitioned)
		#    IMAGE_ROOTFS_ALIGNMENT -> BOOT_SPACE                     - kernel
		#    BOOT_SPACE             -> SDIMG_SIZE                     - rootfs
		#
		#
		#                                                     Default Free space = 1.3x
		#                                                     Use IMAGE_OVERHEAD_FACTOR to add more space
		#                                                     <--------->
		#            4MiB              20MiB           SDIMG_ROOTFS
		# <-----------------------> <----------> <---------------------->
		#  ------------------------ ------------ ------------------------ -------------------------------
		# | IMAGE_ROOTFS_ALIGNMENT | BOOT_SPACE | ROOTFS_SIZE            |     IMAGE_ROOTFS_ALIGNMENT    |
		#  ------------------------ ------------ ------------------------ -------------------------------
		# ^                        ^            ^                        ^                               ^
		# |                        |            |                        |                               |
		# 0                      4MiB     4MiB + 20MiB       4MiB + 20Mib + SDIMG_ROOTFS   4MiB + 20MiB + SDIMG_ROOTFS + 4MiB
		parted -s ${SDIMG} unit KiB mkpart primary ${IMAGE_ROOTFS_ALIGNMENT} $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT})
		parted -s ${SDIMG} unit KiB mkpart primary $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT}) 100%

		# Empty 4 bytes from boot partition
		dd if=/dev/zero of=${SDCARD} conv=notrunc seek=2048 count=4

		# Write the bootstream in (2048 + 4) bytes
		dd if=${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.linux.sb of=${SDCARD} conv=notrunc seek=1 seek=2052
		;;
		u-boot)
		# The disk layout used is:
		#
		#    0                      -> IMAGE_ROOTFS_ALIGNMENT         - bootloader and other data
		#    IMAGE_ROOTFS_ALIGNMENT -> BOOT_SPACE                     - kernel
		#    BOOT_SPACE             -> SDIMG_SIZE                     - rootfs
		#
		#
		#                                                     Default Free space = 1.3x
		#                                                     Use IMAGE_OVERHEAD_FACTOR to add more space
		#                                                     <--------->
		#  1MiB          4MiB              20MiB           SDIMG_ROOTFS
		#  <--> <-----------------------> <----------> <---------------------->
		#  ---------------------------- ------------ ------------------------ -------------------------------
		# |    | IMAGE_ROOTFS_ALIGNMENT | BOOT_SPACE | ROOTFS_SIZE            |     IMAGE_ROOTFS_ALIGNMENT    |
		#  ---- ------------------------ ------------ ------------------------ -------------------------------
		# ^    ^                        ^            ^                        ^                               ^
		# |    |                        |            |                        |                               |
		# 0  1MiB                      4MiB     4MiB + 20MiB       4MiB + 20Mib + SDIMG_ROOTFS   4MiB + 20MiB + SDIMG_ROOTFS + 4MiB
		parted -s ${SDCARD} unit KiB mkpart primary 1024 ${IMAGE_ROOTFS_ALIGNMENT}
		parted -s ${SDCARD} unit KiB mkpart primary ${IMAGE_ROOTFS_ALIGNMENT} $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT})
		parted -s ${SDCARD} unit KiB mkpart primary $(expr ${BOOT_SPACE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT}) 100%

		dd if=${DEPLOY_DIR_IMAGE}/u-boot-${MACHINE}.${UBOOT_SUFFIX_SDCARD} of=${SDCARD} conv=notrunc seek=1 skip=${UBOOT_PADDING} bs=1MiB
		BOOT_BLOCKS=$(LC_ALL=C parted -s ${SDCARD} unit b print \
	        | awk '/ 2 / { print substr($4, 1, length($4 -1)) / 1024 }')

		mkfs.vfat -n "${BOOTDD_VOLUME_ID}" -S 512 -C ${WORKDIR}/boot.img $BOOT_BLOCKS
		mcopy -i ${WORKDIR}/boot.img -s ${DEPLOY_DIR_IMAGE}/uImage-${MACHINE}.bin ::/uImage
		if [ -e "${KERNEL_IMAGETYPE}-${MACHINE}.dtb" ]; then
			kernel_bin="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.bin`"
			kernel_dtb="`readlink ${KERNEL_IMAGETYPE}-${MACHINE}.dtb`"
			if [ `basename $kernel_bin .bin` = `basename $kernel_dtb .dtb` ]; then
				mcopy -i ${WORKDIR}/boot.img -s ${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE}-${MACHINE}.dtb ::/machine.dtb
			fi
		fi

		dd if=${WORKDIR}/boot.img of=${SDCARD} conv=notrunc seek=1 bs=$(expr ${IMAGE_ROOTFS_ALIGNMENT} \* 1024)
		;;
		*)
		bberror "Unkown IMAGE_BOOTLOADER value"
		exit 1
		;;
	esac

	# Change partition type for mxs processor family
	bbnote "Setting partition type to 0x53 as required for mxs' SoC family."
	echo -n S | dd of=${SDCARD} bs=1 count=1 seek=450 conv=notrunc

	parted ${SDCARD} print

	dd if=${SDCARD_ROOTFS} of=${SDCARD} conv=notrunc seek=1 bs=$(expr 1024 \* ${BOOT_SPACE_ALIGNED} + ${IMAGE_ROOTFS_ALIGNMENT} \* 1024)
}

IMAGE_CMD_sdcard () {
	if [ -z "${SDCARD_ROOTFS}" ]; then
		bberror "SDCARD_ROOTFS is undefined. To use sdcard image from Freescale's BSP it needs to be defined."
		exit 1
	fi

	# Align partitions
	BOOT_SPACE_ALIGNED=$(expr ${BOOT_SPACE} + ${IMAGE_ROOTFS_ALIGNMENT} - 1)
	BOOT_SPACE_ALIGNED=$(expr ${BOOT_SPACE_ALIGNED} - ${BOOT_SPACE_ALIGNED} % ${IMAGE_ROOTFS_ALIGNMENT})
	SDIMG_SIZE=$(expr ${IMAGE_ROOTFS_ALIGNMENT} + ${BOOT_SPACE_ALIGNED} + $ROOTFS_SIZE + ${IMAGE_ROOTFS_ALIGNMENT})

	# Initialize a sparse file
	dd if=/dev/zero of=${SDCARD} bs=1 count=0 seek=$(expr 1024 \* ${SDIMG_SIZE})

	${SDCARD_GENERATION_COMMAND}
}
