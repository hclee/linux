#!/bin/bash

KERNEL_VERSION=$1
EXTRA_OPTS=$2
KERNEL_DIR=~/qemu-linux/build-kernel-${KERNEL_VERSION}

install_module() {
	VM_NO=$1
	INST_DIR=~/qemu-linux/host-share-dir/${VM_NO}/${KERNEL_VERSION}

	mkdir -p ${INST_DIR} >& /dev/null
	cp fs/ntfs/ntfs.ko ${KERNEL_DIR}/fs/ntfs
	cp fs/ntfs/ntfs.ko $INST_DIR
	cp fs/ntfs3/ntfs3.ko ${KERNEL_DIR}/fs/ntfs
	cp fs/ntfs3/ntfs3.ko $INST_DIR
}

build_module() {
	MOD_PATH=$1

	echo "# Building ${MOD_PATH}..."
	echo "-----------------"
	make O=${KERNEL_DIR} M=$MOD_PATH C=1 -j7 modules
}

#get_build_kernelversion.sh $KERNEL_DIR $KERNEL_VERSION

if [ $? -ne 0 ]; then
	exit 1
fi

#make KDIR=${KERNEL_DIR} W=1 C=1 -j7 MDIR=$PWD
#CONFIG_NTFS_FS=m
#EXTRA_CFLAGS="-DNTFS_RW -DDEBUG"

build_module "fs/ntfs"
build_module "fs/ntfs3"

echo "INFO: Compiled for $KERNEL_VERSION at $(date)"
install_module vm01
install_module vm02
