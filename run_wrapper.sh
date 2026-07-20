#!/bin/sh
# Run only the commands approved for this workspace.

set -eu

if [ "$#" -eq 0 ]; then
	echo "Usage: $0 {build_kernel|find|ls|chmod|git|sed|reset_test_ntfs|restart_vm|run_xfstests|repeat_xfstests|validate_guest_runner|validate_vm_manager} [arguments...]" >&2
	exit 64
fi

command=$1
shift

case "$command" in
build_kernel)
	if [ "$#" -ne 0 ]; then
		echo "run_wrapper.sh: build_kernel takes no arguments" >&2
		exit 64
	fi
	exec ./make_inst.sh 7.2
	;;
find|ls|chmod|git|sed)
	exec "$command" "$@"
	;;
run_xfstests)
	exec /home/hyunchul/qemu-linux/vm_manager.sh run_xfstests "$@"
	;;
repeat_xfstests)
	if [ "$#" -ne 3 ]; then
		echo "Usage: $0 repeat_xfstests <fstype> <test> <count>" >&2
		exit 64
	fi
	case "$3" in
	''|*[!0-9]*|0)
		echo "run_wrapper.sh: count must be a positive integer" >&2
		exit 64
		;;
	esac
	i=1
	while [ "$i" -le "$3" ]; do
		"$0" git diff --check
		"$0" build_kernel
		"$0" restart_vm
		"$0" reset_test_ntfs
		"$0" run_xfstests "$1" "$2"
		i=$((i + 1))
	done
	;;
restart_vm)
	if [ "$#" -ne 0 ]; then
		echo "run_wrapper.sh: restart_vm takes no arguments" >&2
		exit 64
	fi
	exec /home/hyunchul/qemu-linux/vm_manager.sh restart 7.2
	;;
reset_test_ntfs)
	if [ "$#" -ne 0 ]; then
		echo "run_wrapper.sh: reset_test_ntfs takes no arguments" >&2
		exit 64
	fi
	exec /home/hyunchul/qemu-linux/vm_manager.sh run \
		mkntfs -F -Q -c 4096 /dev/vdc
	;;
validate_guest_runner)
	if [ "$#" -ne 0 ]; then
		echo "run_wrapper.sh: validate_guest_runner takes no arguments" >&2
		exit 64
	fi
	exec bash -n /home/hyunchul/qemu-linux/host-share-dir/agent-automation/guest-run.sh
	;;
validate_vm_manager)
	if [ "$#" -ne 0 ]; then
		echo "run_wrapper.sh: validate_vm_manager takes no arguments" >&2
		exit 64
	fi
	exec bash -n /home/hyunchul/qemu-linux/vm_manager.sh
	;;
*)
	echo "run_wrapper.sh: command not allowed: $command" >&2
	exit 64
	;;
esac
