#
# Write the RK3562 SD-boot chain into the final Doogee U10 image.
#
# The board uses BOOTCONFIG="none", so Armbian builds no U-Boot and the raw
# image has nothing at the BootROM offsets. This extension embeds:
#   sector 64    idbloader.img — BootROM idblock ("RKNS", mkimage -T rksd,
#                TPL rk3562_ddr_1332MHz + SPL). Must NOT be the
#                rk3562_spl_loader_*.bin boot_merger container — that format
#                is for rkdeveloptool/maskrom USB only and the BootROM
#                ignores it, silently falling back to eMMC Android.
#   sector 16384 u-boot.itb — vendor U-Boot FIT.
#
# Blobs live in userpatches/misc/doogee-u10/ and are produced by the
# rk3562deb tree: `make.sh --idblock` for the idblock, `uboot.img` for the FIT.
#
function post_build_image__write_rk3562_sdboot_loader() {
	[[ "${BOARD}" == "doogee-u10" ]] || return 0

	declare blob_dir="${USERPATCHES_PATH}/misc/doogee-u10"
	declare blob
	for blob in idbloader.img u-boot.itb; do
		if [[ ! -f "${blob_dir}/${blob}" ]]; then
			exit_with_error "doogee-u10-sdboot: missing ${blob_dir}/${blob}"
		fi
	done

	# Sanity: idblock must carry the BootROM magic, U-Boot must be a FIT.
	[[ "$(dd if="${blob_dir}/idbloader.img" bs=4 count=1 status=none)" == "RKNS" ]] ||
		exit_with_error "doogee-u10-sdboot: idbloader.img lacks RKNS idblock magic"
	[[ "$(dd if="${blob_dir}/u-boot.itb" bs=4 count=1 status=none | xxd -p)" == "d00dfeed" ]] ||
		exit_with_error "doogee-u10-sdboot: u-boot.itb is not a FIT image"

	display_alert "doogee-u10-sdboot" "writing idblock @64 and u-boot.itb @16384 into ${FINAL_IMAGE_FILE}" "info"
	# The GPT ends at sector 33 and the first partition starts at 32768, so
	# sectors 64..32767 are free for the boot chain.
	run_host_command_logged dd if="${blob_dir}/idbloader.img" of="${FINAL_IMAGE_FILE}" bs=512 seek=64 conv=notrunc status=none
	run_host_command_logged dd if="${blob_dir}/u-boot.itb" of="${FINAL_IMAGE_FILE}" bs=512 seek=16384 conv=notrunc status=none
}
