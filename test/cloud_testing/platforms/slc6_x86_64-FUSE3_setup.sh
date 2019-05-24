#!/bin/sh

# source the common platform independent functionality and option parsing
script_location=$(dirname $(readlink --canonicalize $0))
. ${script_location}/common_setup.sh

echo -n "creating additional disk partitions... "
disk_to_partition=/dev/vda
free_disk_space=$(get_unpartitioned_space $disk_to_partition)
cache_partition_size=16106127360 # 15 GiB
if [ $free_disk_space -lt $cache_partition_size ]; then
  die "fail (not enough unpartitioned disk space - $free_disk_space bytes)"
fi
create_partition $disk_to_partition $cache_partition_size || die "fail (creating partition)"
echo "done"

echo "enabling epel yum repository..."
install_from_repo epel-release

# install CernVM-FS RPM packages
echo "installing RPM packages... "
install_rpm "$CONFIG_PACKAGES"
install_rpm $CLIENT_PACKAGE
install_rpm $UNITTEST_PACKAGE
install_rpm $FUSE3_PACKAGE

# setup environment
echo -n "setting up CernVM-FS environment..."
sudo cvmfs_config setup                          || die "fail (cvmfs_config setup)"
sudo mkdir -p /var/log/cvmfs-test                || die "fail (mkdir /var/log/cvmfs-test)"
sudo chown sftnight:sftnight /var/log/cvmfs-test || die "fail (chown /var/log/cvmfs-test)"
attach_user_group fuse                           || die "fail (add fuse group to user)"
sudo cvmfs_config chksetup > /dev/null           || die "fail (cvmfs_config chksetup)"
echo "done"

# install additional stuff (needed for perl testing tools)
echo "installing additional RPM packages..."
install_from_repo gcc
install_from_repo gcc-c++

# traffic shaping
install_from_repo trickle

# rebooting the system (returning 0 value)
echo "sleep 1 && reboot" > killme.sh
sudo nohup sh < killme.sh &
exit 0
