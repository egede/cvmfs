################################################################################
#                                                                              #
#                              Environment Setup                               #
#                                                                              #
################################################################################

# Configuration variables for update-geodb -l.  May be overridden in
#   /etc/cvmfs/cvmfs_server_hooks.sh or per-repo replica.conf.
# Default settings will attempt to update from cvmfs_server snapshot
#   once every 4 weeks in the 10 o'clock hour of Tuesday.
CVMFS_UPDATEGEO_DAY=2   # Weekday of update, 0-6 where 0 is Sunday, default Tuesday
CVMFS_UPDATEGEO_HOUR=10 # First hour of day for update, 0-23, default 10am
CVMFS_UPDATEGEO_MINDAYS=25 # Minimum days between update attempts
CVMFS_UPDATEGEO_MAXDAYS=100 # Maximum days old before considering it an error

CVMFS_UPDATEGEO_URLBASE="http://geolite.maxmind.com/download/geoip/database"
CVMFS_UPDATEGEO_URLBASE6="${CVMFS_UPDATEGEO_URLBASE}/GeoLiteCityv6-beta"
CVMFS_UPDATEGEO_DIR="/var/lib/cvmfs-server/geo"
CVMFS_UPDATEGEO_DAT="GeoLiteCity.dat"
CVMFS_UPDATEGEO_DAT6="GeoLiteCityv6.dat"

DEFAULT_LOCAL_STORAGE="/srv/cvmfs"

LATEST_JSON_INFO_SCHEMA=1

# setup server hooks: no-ops (overrideable by /etc/cvmfs/cvmfs_server_hooks.sh)
transaction_before_hook() { :; }
transaction_after_hook() { :; }
abort_before_hook() { :; }
abort_after_hook() { :; }
publish_before_hook() { :; }
publish_after_hook() { :; }

[ -f /etc/cvmfs/cvmfs_server_hooks.sh ] && . /etc/cvmfs/cvmfs_server_hooks.sh

find_sbin() {
  local bin_name="$1"
  local bin_path=""
  for d in /sbin /usr/sbin /usr/local/sbin /bin /usr/bin /usr/local/bin; do
    bin_path="${d}/${bin_name}"
    if [ -x "$bin_path" ]; then
      echo "$bin_path"
      return 0
    fi
  done
  return 1
}

# Path to some useful sbin utilities
LSOF_BIN="$(find_sbin       lsof)"       || true
GETENFORCE_BIN="$(find_sbin getenforce)" || true
SESTATUS_BIN="$(find_sbin   sestatus)"   || true
GETCAP_BIN="$(find_sbin     getcap)"     || true
SETCAP_BIN="$(find_sbin     setcap)"     || true
MODPROBE_BIN="$(find_sbin   modprobe)"   || true
PIDOF_BIN="$(find_sbin      pidof)"      || true
RUNUSER_BIN="$(find_sbin    runuser)"    || true

# Find out how to deal with Apache
# (binary name, configuration directory, CLI, WSGI module name, ...)
if find_sbin httpd2 > /dev/null 2>&1; then # SLES/OpenSuSE
  APACHE_CONF="apache2"
  APACHE_BIN="$(find_sbin httpd2)"
  APACHE_CTL="$APACHE_BIN"
  APACHE_WSGI_MODPKG="apache2-mod_wsgi"
elif find_sbin apache2 > /dev/null 2>&1; then
  APACHE_CONF="apache2"
  APACHE_BIN="$(find_sbin apache2)"
  if find_sbin apachectl > /dev/null 2>&1; then # Debian
    APACHE_CTL="$(find_sbin apachectl)"
    APACHE_WSGI_MODPKG="libapache2-mod-wsgi"
  elif find_sbin apache2ctl > /dev/null 2>&1; then # Gentoo
    APACHE_CTL="$(find_sbin apache2ctl)"
    APACHE_WSGI_MODPKG="www-apache/mod_wsgi"
  fi
else # RedHat based
  APACHE_CONF="httpd"
  APACHE_BIN="/usr/sbin/httpd"
  APACHE_CTL="$APACHE_BIN"
  APACHE_WSGI_MODPKG="mod_wsgi"
fi

# Find the service binary (or detect systemd)
minpidof() {
  $PIDOF_BIN $1 | tr " " "\n" | sort --numeric-sort | head -n1
}
SERVICE_BIN="false"
if ! $PIDOF_BIN systemd > /dev/null 2>&1 || [ $(minpidof systemd) -ne 1 ]; then
  if [ -x /sbin/service ]; then
    SERVICE_BIN="/sbin/service"
  elif [ -x /usr/sbin/service ]; then
    SERVICE_BIN="/usr/sbin/service" # Ubuntu
  elif [ -x /sbin/rc-service ]; then
    SERVICE_BIN="/sbin/rc-service" # OpenRC
  else
    die "Neither systemd nor service binary detected"
  fi
fi

# Check if `runuser` is available on this system
# Note: at least Ubuntu in older versions doesn't provide this command
HAS_RUNUSER=0
if [ -x "$RUNUSER_BIN" ]; then
  HAS_RUNUSER=1
fi

is_systemd() {
  [ x"$SERVICE_BIN" = x"false" ]
}

# standard values
CVMFS_DEFAULT_USE_FILE_CHUNKING=true
CVMFS_DEFAULT_MIN_CHUNK_SIZE=4194304
CVMFS_DEFAULT_AVG_CHUNK_SIZE=8388608
CVMFS_DEFAULT_MAX_CHUNK_SIZE=16777216
CVMFS_DEFAULT_CATALOG_ENTRY_WARN_THRESHOLD=500000

CVMFS_SERVER_DEBUG=${CVMFS_SERVER_DEBUG:=0}
CVMFS_SERVER_SWISSKNIFE="cvmfs_swissknife"
CVMFS_SERVER_SWISSKNIFE_DEBUG=$CVMFS_SERVER_SWISSKNIFE

################################################################################
#                                                                              #
#                              Utility Functions                               #
#                                                                              #
################################################################################

# enable the debug mode?
if [ $CVMFS_SERVER_DEBUG -ne 0 ]; then
  if [ -f /usr/bin/cvmfs_swissknife_debug ]; then
    case $CVMFS_SERVER_DEBUG in
      1)
        # in case something breaks we are provided with a GDB prompt.
        CVMFS_SERVER_SWISSKNIFE_DEBUG="gdb --quiet --eval-command=run --eval-command=quit --args cvmfs_swissknife_debug"
      ;;
      2)
        # attach gdb and provide a prompt WITHOUT actual running the program
        CVMFS_SERVER_SWISSKNIFE_DEBUG="gdb --quiet --args cvmfs_swissknife_debug"
      ;;
      3)
        # do not attach gdb just run debug version
        CVMFS_SERVER_SWISSKNIFE_DEBUG="cvmfs_swissknife_debug"
      ;;
    esac
  else
    echo -e "WARNING: compile with CVMFS_SERVER_DEBUG to allow for debug mode!\nFalling back to release mode...."
  fi
fi

# checks if the given command name is a supported command of cvmfs_server
#
# @param subcommand   the subcommand to be called
# @return   0 if the command was recognized
is_subcommand() {
  local subcommand="$1"
  local supported_commands="mkfs add-replica import publish rollback rmfs alterfs    \
    resign list info tag list-tags lstags check transaction abort snapshot           \
    skeleton migrate list-catalogs update-geodb gc catalog-chown eliminate-hardlinks \
    update-info update-repoinfo mount fix-permissions"

  for possible_command in $supported_commands; do
    if [ x"$possible_command" = x"$subcommand" ]; then
      return 0
    fi
  done

  return 1
}


is_redhat() {
  [ -f /etc/redhat-release ]
}

# whenever you print the version string you should use this function since
# a repository created before CernVM-FS 2.1.7 cannot be fingerprinted
# correctly...
# @param version_string  the plain version string
mangle_version_string() {
  local version_string=$1
  if [ x"$version_string" = x"2.1.6" ]; then
    echo "2.1.6 or lower"
  else
    echo $version_string
  fi
}

# checks if the aufs kernel module is present
# or if aufs is compiled in
# @return   0 if the aufs kernel module is loaded
check_aufs() {
  $MODPROBE_BIN -q aufs || test -d /sys/fs/aufs
}


# checks if the overlayfs kernel module is present
# or if overlayfs is compiled in
# @return   0 if the overlayfs kernel module is loaded
check_overlayfs() {
  $MODPROBE_BIN -q overlay || test -d /sys/module/overlay
}


# ensure that the installed overlayfs is viable for CernVM-FS. Namely, it must
# be part of the upstream kernel (since 3.18) and recent enough (kernel 4.2)
# Note: More details are in CVM-835.
# @return  0 if overlayfs is installed and viable
check_overlayfs_version() {
  [ -z "$CVMFS_DONT_CHECK_OVERLAYFS_VERSION" ] || return 0
  local krnl_version=$(uname -r | grep -oe '^[0-9]\+\.[0-9]\+.[0-9]\+')
  compare_versions "$krnl_version" -ge "4.2.0"
}


# check if at least one of the supported union file systems is available
# currently AUFS get preference over OverlayFS if both are available
#
# @return   0 if at least one was found (name through stdout); abort otherwise
get_available_union_fs() {
  if check_aufs; then
    echo "aufs"
  elif check_overlayfs; then
    echo "overlayfs"
  else
    die "neither AUFS nor OverlayFS detected on the system!"
  fi
}


request_apache_service() {
  local request_verb="$1"
  if is_systemd; then
    /bin/systemctl $request_verb ${APACHE_CONF}
  else
    $SERVICE_BIN $APACHE_CONF $request_verb
  fi
}

# checks if apache is installed and running
#
# @return  0 if apache is installed and running
check_apache() {
  [ -d /etc/${APACHE_CONF} ] && request_apache_service status > /dev/null
}

reload_apache() {
  echo -n "Reloading Apache... "
  request_apache_service reload > /dev/null || die "fail"
  echo "done"
}

restart_apache() {
  echo -n "Restarting Apache... "
  request_apache_service restart > /dev/null || die "fail"
  echo "done"
}

check_apache_module() {
  local module_name="$1"
  ${APACHE_CTL} -M 2>&1 | grep -q "$module_name"
}

# checks if wsgi apache module is installed and enabled
check_wsgi_module() {
  if check_apache_module "wsgi_module"; then
    return 0
  fi

  echo "The apache wsgi module must be installed and enabled.
The required package is called ${APACHE_WSGI_MODPKG}."
  if is_redhat; then
    case "`cat /etc/redhat-release`" in
      *"release 5."*)
        if [ -f /etc/httpd/conf.d/wsgi.conf ]; then
          # older el5 epel versions didn't automatically enable it
          echo "To enable the module, see instructions in /etc/httpd/conf.d/wsgi.conf"
        else
          echo "The package is in the epel yum repository."
        fi
        ;;
    esac
  fi
  exit 1
}


# retrieves the apache version string
get_apache_version() {
  ${APACHE_BIN} -v | head -n1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+'
}

get_apache_conf_filename() {
  local name=$1
  echo "cvmfs.${name}.conf"
}

# figure out apache config file mode
#
# @return   apache config mode (stdout) (see globals below)
APACHE_CONF_MODE_CONFD=1     # *.conf goes to ${APACHE_CONF}/conf.d
APACHE_CONF_MODE_CONFAVAIL=2 # *.conf goes to ${APACHE_CONF}/conf-available
get_apache_conf_mode() {
  [ -d /etc/${APACHE_CONF}/conf-available ] && echo $APACHE_CONF_MODE_CONFAVAIL \
                                            || echo $APACHE_CONF_MODE_CONFD
}


set_selinux_httpd_context_if_needed() {
  local directory="$1"
  if has_selinux; then
    chcon -Rv --type=httpd_sys_content_t ${directory}/ > /dev/null
  fi
}


# find location of apache configuration files
#
# @return   the location of apache configuration files (stdout)
get_apache_conf_path() {
  local res_path="/etc/${APACHE_CONF}"
  if [ x"$(get_apache_conf_mode)" = x"$APACHE_CONF_MODE_CONFAVAIL" ]; then
    echo "${res_path}/conf-available"
  elif [ -d "${res_path}/modules.d" ]; then
    echo "${res_path}/modules.d"
  else
    echo "${res_path}/conf.d"
  fi
}


# returns the apache configuration string for 'allow from all'
# Note: this is necessary, since apache 2.4.x formulates that different
#
# @return   a configuration snippet to allow s'th from all hosts (stdout)
get_compatible_apache_allow_from_all_config() {
  local minor_apache_version=$(version_minor "$(get_apache_version)")
  if [ $minor_apache_version -ge 4 ]; then
    echo "Require all granted"
  else
    local nl='
'
    echo "Order allow,deny${nl}    Allow from all"
  fi
}


# writes apache configuration file
# This figures out where to put the apache configuration file depending
# on the running apache version
# Note: Configuration file content is expected to come through stdin
#
# @param   file_name  the name of the apache config file (no path!)
# @return             0 on succes
create_apache_config_file() {
  local file_name=$1
  local conf_path
  conf_path="$(get_apache_conf_path)"

  # create (or append) the conf file
  cat - > ${conf_path}/${file_name} || return 1

  # the new apache requires the enable the config afterwards
  if [ x"$(get_apache_conf_mode)" = x"$APACHE_CONF_MODE_CONFAVAIL" ]; then
    a2enconf $file_name > /dev/null || return 2
  fi

  return 0
}


# removes apache config files dependent on the apache version in place
# Note: As of apache 2.4.x `a2disconf` needs to be called before removal
#
# @param   file_name  the name of the conf file to be removed (no path!)
# @return  0 on successful removal
remove_apache_config_file() {
  local file_name=$1
  local conf_path
  conf_path="$(get_apache_conf_path)/${file_name}"

  # disable configuration on newer apache versions
  if [ x"$(get_apache_conf_mode)" = x"$APACHE_CONF_MODE_CONFAVAIL" ]; then
    a2disconf $file_name > /dev/null 2>&1 || return 1
  fi

  # remove configuration file
  rm -f $conf_path
}


# check if an apache configuration file exists. This looks in the appropriate
# place, depending on the installed apache version.
has_apache_config_file() {
  local file_name=$1
  local conf_path
  conf_path="$(get_apache_conf_path)/${file_name}"
  [ -f $conf_path ]
}


get_fd_modes() {
  local path=$1
  $LSOF_BIN -Fan 2>/dev/null | grep -B1 -e "^n$path" | grep -e '^a.*'
}

# gets the number of open read-only file descriptors beneath a given path
#
# @param path  the path to look at for open read-only fds
# @return      the number of open read-only file descriptors
count_rd_only_fds() {
  local path=$1
  local cnt=0
  for line in $(get_fd_modes $path); do
    if echo "$line" | grep -qe '^\ar\?$';  then cnt=$(( $cnt + 1 )); fi
  done
  echo $cnt
}

# find the partition name for a given file path
#
# @param   path  the path to the file to be checked
# @return  the name of the partition that path resides on
get_partition_for_path() {
  local path="$1"
  df --portability "$path" | tail -n1 | awk '{print $1}'
}


# checks if cvmfs2 client is installed
#
# @return  0 if cvmfs2 client is installed
check_cvmfs2_client() {
  [ -x /usr/bin/cvmfs2 ]
}


# checks if a given repository is replicable
#
# @param name   the repository name or URL to be checked
# @return       0 if it is a stratum0 repository and replicable
is_master_replica() {
  local name=$1
  local is_master_replica

  if [ $(echo $name | cut --bytes=1-7) = "http://" ]; then
    is_master_replica=$(get_repo_info_from_url $name -m -L)
  else
    load_repo_config $name
    is_stratum0 $name || return 1
    is_master_replica=$(get_repo_info -m)
  fi

  [ "x$is_master_replica" = "xtrue" ]
}


# checks if the (corresponding) stratum 0 is garbage collectable
#
# @param name  the name of the stratum1/stratum0 repository to be checked
# @return      0 if it is garbage collectable
is_stratum0_garbage_collectable() {
  local name=$1
  load_repo_config $name
  [ x"$(get_repo_info_from_url $CVMFS_STRATUM0 -g)" = x"yes" ]
}


# checks if a manifest ist present
#
# @param name  the name of the repository to be checked
# @return      0 if it is empty
is_empty_repository() {
  local name=$1
  local url=""
  load_repo_config $name
  is_stratum0 $name && url="$CVMFS_STRATUM0" || url="$CVMFS_STRATUM1"
  [ x"$(get_repo_info_from_url "$url" -e)" = x"yes" ]
}

# checks if a repository contains a reference log that is necessary to run
# garbage collections
#
# @param name  the name of the repository to be checked
# @return      0 if it contains a reference log
has_reference_log() {
  local name=$1
  local url=""
  load_repo_config $name
  is_stratum0 $name && url="$CVMFS_STRATUM0" || url="$CVMFS_STRATUM1"
  [ x"$(get_repo_info_from_url "$url" -o)" = x"true" ]
}


# checks if a the reflog checksum is present in the spool directory
#
# @param name  the name of the repository to be checked
# @return      0 if the reflog checksum is available
has_reflog_checksum() {
  local name=$1

  [ -f $(get_reflog_checksum $name) ]
}


# get the configured (or default) timespan for an automatic garbage
# collection run.
#
# @param name  the name of the repository to be checked
# @return      the configured CVMFS_AUTO_GC_TIMESPAN or default (3 days ago)
#              as a timestamp threshold (unix timestamp)
#              Note: in case of a malformed timespan it might print an error to
#                     stderr and return a non-zero code
get_auto_garbage_collection_timespan() {
  local name=$1
  local timespan="3 days ago"

  load_repo_config $name
  if [ ! -z "$CVMFS_AUTO_GC_TIMESPAN" ]; then
    timespan="$CVMFS_AUTO_GC_TIMESPAN"
  fi

  if ! date --date "$timespan" +%s 2>/dev/null; then
    echo "Failed to parse CVMFS_AUTO_GC_TIMESPAN: '$timespan'" >&2
    return 1
  fi
}


# checks if a user exists in the system
#
# @param user   the name of the user to be checked
# @return       0 if user was found
check_user() {
  local user=$1
  id $user > /dev/null 2>&1
}


has_selinux() {
  [ -x $SESTATUS_BIN   ] && \
  [ -x $GETENFORCE_BIN ] && \
  $GETENFORCE_BIN | grep -qi "enforc" || return 1
}


_cleanup_tmrc() {
  local tmpdir=$1
  umount ${tmpdir}/c > /dev/null 2>&1 || umount -l > /dev/null 2>&1
  rm -fR ${tmpdir}   > /dev/null 2>&1
}

# for some reason `mount -o remount,(ro|rw) /cvmfs/$name` does not work on older
# platforms if we set the SELinux context=... parameter in /etc/fstab
# this dry-runs the whole mount, remount, unmount cycle to find out if it works
# correctly (aufs version)
# @returns  0 if the whole cycle worked as expected
try_mount_remount_cycle_aufs() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir ${tmpdir}/a ${tmpdir}/b ${tmpdir}/c
  mount -t aufs \
    -o br=${tmpdir}/a=ro:${tmpdir}/b=rw,ro,context=system_u:object_r:default_t:s0 \
    try_remount_aufs ${tmpdir}/c  > /dev/null 2>&1 || return 1
  mount -o remount,rw ${tmpdir}/c > /dev/null 2>&1 || { _cleanup_tmrc $tmpdir; return 2; }
  mount -o remount,ro ${tmpdir}/c > /dev/null 2>&1 || { _cleanup_tmrc $tmpdir; return 3; }
  _cleanup_tmrc $tmpdir
  return 0
}


# checks if the right number of arguments was provided
# if the wrong number was provided it will kill the script after printing the
# usage text and an error message
#
# @param expected_parameter_count   number of expected parameters
# @param provided_parameter_count   number of provided parameters
check_parameter_count() {
  local expected_parameter_count=$1
  local provided_parameter_count=$2

  if [ $provided_parameter_count -lt $expected_parameter_count ]; then
    usage "Too few arguments provided"
  fi
  if [ $provided_parameter_count -gt $expected_parameter_count ]; then
    usage "Too many arguments provided"
  fi
}


# mangles the repository name into a fully qualified repository name
# if there was no repository name given and there is only one repository present
# in the system, it automatically returns the name of this one.
#
# @param repository_name  the name of the repository to work on (might be empty)
# @return                 echoes a suitable repository name
get_or_guess_repository_name() {
  local repository_name=$1

  if [ "x$repository_name" = "x" ]; then
    echo $(get_repository_name $(ls /etc/cvmfs/repositories.d))
  else
    echo $(get_repository_name $repository_name)
  fi
}


# looks for traces of CernVM-FS 2.0.x which is incompatible with CernVM-FS 2.1.x
# and interferes with each other
foreclose_legacy_cvmfs() {
  local found_something=0

  if [ -f /etc/cvmfs/server.conf ] || [ -f /etc/cvmfs/replica.conf ]; then
    echo "found legacy configuration files in /etc/cvmfs" 1>&2
    found_something=1
  fi

  if which cvmfs-sync     > /dev/null 2>&1 || \
     which cvmfs_scrub    > /dev/null 2>&1 || \
     which cvmfs_snapshot > /dev/null 2>&1 || \
     which cvmfs_zpipe    > /dev/null 2>&1 || \
     which cvmfs_pull     > /dev/null 2>&1 || \
     which cvmfs_unsign   > /dev/null 2>&1; then
    echo "found legacy CernVM-FS executables" 1>&2
    found_something=1
  fi

  if [ -f /lib/modules/*/extra/cvmfsflt/cvmfsflt.ko ]; then
    echo "found CernVM-FS 2.0.x kernel module" 1>&2
    found_something=1
  fi

  if [ $found_something -ne 0 ]; then
    echo "found traces of CernVM-FS 2.0.x! You should remove them before proceeding!"
    exit 1
  fi

  return $found_something
}


create_master_key() {
  local name=$1
  local user=$2

  master_key="/etc/cvmfs/keys/$name.masterkey"
  master_pub="/etc/cvmfs/keys/$name.pub"

  openssl genrsa -out $master_key 2048 > /dev/null 2>&1
  openssl rsa -in $master_key -pubout -out $master_pub > /dev/null 2>&1
  chmod 400 $master_key
  chmod 444 $master_pub
  chown $user $master_key $master_pub
}


create_cert() {
  local name=$1
  local user=$2

  local key; key="/etc/cvmfs/keys/$name.key"
  local csr; csr="/etc/cvmfs/keys/$name.csr"
  local crt; crt="/etc/cvmfs/keys/$name.crt"

  # Create self-signed certificate
  openssl genrsa -out $key 2048 > /dev/null 2>&1
  openssl req -new -subj "/C=/ST=/L=/O=/OU=/CN=$name CernVM-FS Release Managers" -key $key -out $csr > /dev/null 2>&1
  openssl x509 -req -days 365 -in $csr -signkey $key -out $crt > /dev/null 2>&1
  rm -f $csr
  chmod 444 $crt
  chmod 400 $key
  chown $user $crt $key
}


create_whitelist() {
  local name=$1
  local user=$2
  local spooler_definition=$3
  local temp_dir=$4

  local whitelist
  whitelist=${temp_dir}/whitelist.$name

  echo -n "Signing 30 day whitelist with master key... "
  echo `date -u "+%Y%m%d%H%M%S"` > ${whitelist}.unsigned
  echo "E`date -u --date='+30 days' "+%Y%m%d%H%M%S"`" >> ${whitelist}.unsigned
  echo "N$name" >> ${whitelist}.unsigned
  openssl x509 -in /etc/cvmfs/keys/${name}.crt -outform der | \
    __swissknife hash -a $CVMFS_HASH_ALGORITHM -f >> ${whitelist}.unsigned

  local hash;
  hash="`cat ${whitelist}.unsigned | __swissknife hash -a $CVMFS_HASH_ALGORITHM`"
  echo "--" >> ${whitelist}.unsigned
  echo $hash >> ${whitelist}.unsigned
  echo -n $hash > ${whitelist}.hash
  openssl rsautl -inkey /etc/cvmfs/keys/${name}.masterkey -sign -in ${whitelist}.hash -out ${whitelist}.signature
  cat ${whitelist}.unsigned ${whitelist}.signature > $whitelist
  chown $user $whitelist

  rm -f ${whitelist}.unsigned ${whitelist}.signature ${whitelist}.hash
  __swissknife upload -i $whitelist -o .cvmfswhitelist -r $spooler_definition
  rm -f $whitelist
  echo "done"
}


# this strips both the attached signature block and the certificate hash from
# an already signed manifest file and prints the result to stdout
strip_manifest_signature() {
  local signed_manifest="$1"
  # print lines starting with a capital letter (except X for the certificate)
  # and stop as soon as we find the signature delimiter '--'
  awk '/^[A-WY-Z]/ {print $0}; /--/ {exit}' $signed_manifest
}


check_upstream_validity() {
  local upstream=$1
  local silent=0
  if [ $# -gt 1 ]; then
    silent=1;
  fi

  # checks if $upstream contains _exactly three_ comma separated data fields
  if echo $upstream | grep -q "^[^,]*,[^,]*,[^,]*$"; then
    return 0
  fi

  if [ $silent -ne 1 ]; then
    usage "The given upstream definition (-u) is invalid. Should look like:
      <spooler type> , <tmp directory> , <spooler configuration>"
  fi
  return 1
}

is_s3_upstream() {
  local upstream=$1
  check_upstream_type $upstream "s3"
}

get_upstream_config() {
  local upstream=$1
  echo "$upstream" | cut -d, -f3-
}

make_upstream() {
  local type_name=$1
  local tmp_dir=$2
  local config_string=$3
  echo "$type_name,$tmp_dir,$config_string"
}

make_local_upstream() {
  local repo_name=$1
  local repo_storage="${DEFAULT_LOCAL_STORAGE}/${repo_name}"
  make_upstream "local" "${repo_storage}/data/txn" "$repo_storage"
}

make_s3_upstream() {
  local repo_name=$1
  local s3_config=$2
  make_upstream "S3" "/var/spool/cvmfs/${repo_name}/tmp" "${repo_name}@${s3_config}"
}

mangle_local_cvmfs_url() {
  local repo_name=$1
  echo "http://localhost/cvmfs/${repo_name}"
}

mangle_s3_cvmfs_url() {
  local repo_name=$1
  local s3_url="$2"
  [ $(echo -n "$s3_url" | tail -c1) = "/" ] || s3_url="${s3_url}/"
  echo "${s3_url}${repo_name}"
}

# lowers restrictions of hardlink creation if needed
# allows AUFS to properly whiteout files without root privileges
# Note: this function requires a privileged user
lower_hardlink_restrictions() {
  if [ -f /proc/sys/kernel/yama/protected_nonaccess_hardlinks ] && \
     [ $(cat /proc/sys/kernel/yama/protected_nonaccess_hardlinks) -ne 0 ]; then
    # disable hardlink restrictions at runtime
    sysctl -w kernel.yama.protected_nonaccess_hardlinks=0 > /dev/null 2>&1 || return 1

    # change sysctl.conf to make the change persist reboots
    cat >> /etc/sysctl.conf << EOF

# added by CVMFS to allow proper whiteout of files in AUFS
# when creating or altering repositories on this machine.
kernel.yama.protected_nonaccess_hardlinks=0
EOF
    echo "Note: permanently disabled kernel option: kernel.yama.protected_nonaccess_hardlinks"
  fi

  return 0
}

_setcap_if_needed() {
  local binary_path="$1"
  local capability="$2"
  [ -x $binary_path ]                                || return 0
  $GETCAP_BIN "$binary_path" | grep -q "$capability" && return 0
  $SETCAP_BIN "${capability}+p" "$binary_path"
}

# grants CAP_SYS_ADMIN to cvmfs_swissknife if it is necessary
# Note: OverlayFS uses trusted extended attributes that are not readable by a
#       normal unprivileged process
ensure_swissknife_suid() {
  local unionfs="$1"
  local sk_bin="/usr/bin/$CVMFS_SERVER_SWISSKNIFE"
  local sk_dbg_bin="/usr/bin/${CVMFS_SERVER_SWISSKNIFE}_debug"
  local cap="cap_sys_admin"

  # check if we need CAP_SYS_ADMIN for cvmfs_swissknife...
  is_root || die "need to be root for granting CAP_SYS_ADMIN to $sk_bin"
  [ x"$unionfs" = x"overlayfs" ] || return 0

  # ... yes, obviously we need CAP_SYS_ADMIN for cvmfs_swissknife
  _setcap_if_needed "$sk_bin"     "$cap" || return 1
  _setcap_if_needed "$sk_dbg_bin" "$cap" || return 2
}


# cvmfs requires a couple of apache modules to be enabled when running on
# an ubuntu machine. This enables these modules on an ubuntu installation
# Note: this function requires a privileged user
ensure_enabled_apache_modules() {
  local a2enmod_bin=
  local apache2ctl_bin=
  a2enmod_bin="$(find_sbin    a2enmod)"    || return 0
  apache2ctl_bin="$(find_sbin apache2ctl)" || return 0

  local restart=0
  local retcode=0
  local modules="headers expires"

  for module in $modules; do
    $apache2ctl_bin -M 2>/dev/null | grep -q "$module" && continue
    $a2enmod_bin $module > /dev/null 2>&1 || { echo "Warning: failed to enable apache2 module $module"; retcode=1; }
    restart=1
  done

  # restart apache if needed
  if [ $restart -ne 0 ]; then
    restart_apache 2>/dev/null | { echo "Warning: Failed to restart apache after enabling necessary modules"; retcode=2; }
  fi

  return $retcode
}


create_repository_skeleton() {
  local directory=$1
  local user=$2

  echo -n "Creating repository skeleton in ${directory}..."
  mkdir -p ${directory}/data
  local i=0
  while [ $i -lt 256 ]
  do
    mkdir -p ${directory}/data/$(printf "%02x" $i)
    i=$(($i+1))
  done
  mkdir -p ${directory}/data/txn
  if [ x$(id -un) != x$user ]; then
    chown -R $user ${directory}/
  fi
  set_selinux_httpd_context_if_needed $directory
  echo "done"
}


get_cvmfs_owner() {
  local name=$1
  local owner=$2
  local cvmfs_owner

  if [ "x$owner" = "x" ]; then
    read -p "Owner of $name [$(whoami)]: " cvmfs_owner
    [ x"$cvmfs_owner" = x ] && cvmfs_owner=$(whoami)
  else
    cvmfs_owner=$owner
  fi
  check_user $cvmfs_user || return 1
  echo $cvmfs_owner
}


# get the configured timespan for removing old auto-generated tags.
#
# @param name  the name of the repository to be checked
# @return      the configured CVMFS_AUTO_TAG_TIMESPAN or 0 (forever)
#              as a timestamp threshold (unix timestamp)
#              Note: in case of a malformed timespan it might print an error to
#                     stderr and return a non-zero code
get_auto_tags_timespan() {
  local repository_name=$1

  load_repo_config $repository_name
  local timespan="$CVMFS_AUTO_TAG_TIMESPAN"
  if [ -z "$timespan" ]; then
    echo "0"
    return 0
  fi

  if ! date --date "$timespan" +%s 2>/dev/null; then
    echo "Failed to parse CVMFS_AUTO_TAG_TIMESPAN: '$timespan'" >&2
    return 1
  fi
  return 0
}


migrate_legacy_dirtab() {
  local name=$1
  local dirtab_path="/cvmfs/${name}/.cvmfsdirtab"
  local tmp_dirtab=$(mktemp)

  cp -f "$dirtab_path" "$tmp_dirtab"                           || return 1
  cvmfs_server_transaction $name > /dev/null                   || return 2
  cat "$tmp_dirtab" | sed -e 's/\(.*\)/\1\/\*/' > $dirtab_path || return 3
  cvmfs_server_publish $name > /dev/null                       || return 4
  rm -f "$tmp_dirtab"                                          || return 5
}


# sends wsgi configuration to stdout
#
# @param name        the name of the repository
# @param with_wsgi   if not set, this function is a NOOP
cat_wsgi_config() {
  local name=$1
  local with_wsgi="$2"

  [ x"$with_wsgi" != x"" ] || return 0
  echo "# Enable api functions
WSGIPythonPath /usr/share/cvmfs-server/webapi
Alias /cvmfs/$name/api /var/www/wsgi-scripts/cvmfs-api.wsgi/$name

<Directory /var/www/wsgi-scripts>
    Options ExecCGI
    SetHandler wsgi-script
    Order allow,deny
    Allow from all
</Directory>
"
}


# creates a standard Apache configuration file for a repository
#
# @param name         the name of the endpoint to be served
# @param storage_dir  the storage location of the data
# @param with_wsgi    whether or not to enable WSGI api functions
create_apache_config_for_endpoint() {
  local name=$1
  local storage_dir=$2
  local with_wsgi="$3"

  create_apache_config_file "$(get_apache_conf_filename $name)" << EOF
# Created by cvmfs_server.  Don't touch.
$(cat_wsgi_config $name $with_wsgi)

KeepAlive On
AddType application/json .json
# Translation URL to real pathname
Alias /cvmfs/${name} ${storage_dir}
<Directory "${storage_dir}">
    Options -MultiViews
    AllowOverride Limit
    $(get_compatible_apache_allow_from_all_config)

    EnableMMAP Off
    EnableSendFile Off

    <FilesMatch "^\.cvmfs">
        ForceType application/x-cvmfs
    </FilesMatch>

    Header unset Last-Modified
    FileETag None

    ExpiresActive On
    ExpiresDefault "access plus 3 days"
    ExpiresByType application/x-cvmfs "access plus 2 minutes"
    ExpiresByType application/json    "access plus 2 minutes"
</Directory>
EOF
}

has_apache_config_for_global_info() {
  has_apache_config_file $(get_apache_conf_filename "info")
}

create_apache_config_for_global_info() {
  ! has_apache_config_for_global_info || return 0
  local storage_dir="${DEFAULT_LOCAL_STORAGE}/info"
  create_apache_config_for_endpoint "info" "$storage_dir"
}

# puts all configuration files in place that are need for a stratum0 repository
#
# @param name        the name of the repository
# @param upstream    the upstream definition of the future repository
# @param stratum0    the URL of the stratum0 http entry point
# @param cvmfs_user  the owning user of the repository
create_config_files_for_new_repository() {
  local name=$1
  local upstream=$2
  local stratum0=$3
  local cvmfs_user=$4
  local unionfs=$5
  local hash_algo=$6
  local autotagging=$7
  local garbage_collectable=$8
  local configure_apache=$9
  local compression_alg=${10}
  local external_data=${11}
  local voms_authz=${12}
  local auto_tag_timespan="${13}"

  # other configurations
  local spool_dir="/var/spool/cvmfs/${name}"
  local scratch_dir="${spool_dir}/scratch/current"
  local rdonly_dir="${spool_dir}/rdonly"
  local temp_dir="${spool_dir}/tmp"
  local cache_dir="${spool_dir}/cache"
  local repo_cfg_dir="/etc/cvmfs/repositories.d/${name}"
  local server_conf="${repo_cfg_dir}/server.conf"
  local client_conf="${repo_cfg_dir}/client.conf"

  mkdir -p $repo_cfg_dir
  cat > $server_conf << EOF
# Created by cvmfs_server.
CVMFS_CREATOR_VERSION=$(cvmfs_version_string)
CVMFS_REPOSITORY_NAME=$name
CVMFS_REPOSITORY_TYPE=stratum0
CVMFS_USER=$cvmfs_user
CVMFS_UNION_DIR=/cvmfs/$name
CVMFS_SPOOL_DIR=$spool_dir
CVMFS_STRATUM0=$stratum0
CVMFS_UPSTREAM_STORAGE=$upstream
CVMFS_USE_FILE_CHUNKING=$CVMFS_DEFAULT_USE_FILE_CHUNKING
CVMFS_MIN_CHUNK_SIZE=$CVMFS_DEFAULT_MIN_CHUNK_SIZE
CVMFS_AVG_CHUNK_SIZE=$CVMFS_DEFAULT_AVG_CHUNK_SIZE
CVMFS_MAX_CHUNK_SIZE=$CVMFS_DEFAULT_MAX_CHUNK_SIZE
CVMFS_CATALOG_ENTRY_WARN_THRESHOLD=$CVMFS_DEFAULT_CATALOG_ENTRY_WARN_THRESHOLD
CVMFS_UNION_FS_TYPE=$unionfs
CVMFS_HASH_ALGORITHM=$hash_algo
CVMFS_COMPRESSION_ALGORITHM=$compression_alg
CVMFS_EXTERNAL_DATA=$external_data
CVMFS_AUTO_TAG=$autotagging
CVMFS_AUTO_TAG_TIMESPAN="$auto_tag_timespan"
CVMFS_GARBAGE_COLLECTION=$garbage_collectable
CVMFS_AUTO_REPAIR_MOUNTPOINT=true
CVMFS_AUTOCATALOGS=false
CVMFS_ASYNC_SCRATCH_CLEANUP=true
EOF

  if [ x"$voms_authz" != x"" ]; then
    echo "CVMFS_VOMS_AUTHZ=$voms_authz" >> $server_conf
    echo "CVMFS_CATALOG_ALT_PATHS=true" >> $server_conf
  fi

  # append GC specific configuration
  if [ x"$garbage_collectable" = x"true" ]; then
    cat >> $server_conf << EOF
CVMFS_AUTO_GC=true
EOF
  fi

  if [ $configure_apache -eq 1 ] && is_local_upstream $upstream; then
    local repository_dir=$(get_upstream_config $upstream)
    # make sure that the config file does not exist, yet
    remove_apache_config_file "$(get_apache_conf_filename $name)" || true
    create_apache_config_for_endpoint $name $repository_dir
    create_apache_config_for_global_info
  fi

  cat > $client_conf << EOF
# Created by cvmfs_server.  Don't touch.
CVMFS_CACHE_BASE=$cache_dir
CVMFS_RELOAD_SOCKETS=$cache_dir
CVMFS_QUOTA_LIMIT=4000
CVMFS_MOUNT_DIR=/cvmfs
CVMFS_SERVER_URL=$stratum0
CVMFS_HTTP_PROXY=DIRECT
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${name}.pub
CVMFS_TRUSTED_CERTS=${repo_cfg_dir}/trusted_certs
CVMFS_CHECK_PERMISSIONS=yes
CVMFS_IGNORE_SIGNATURE=no
CVMFS_AUTO_UPDATE=no
CVMFS_NFS_SOURCE=no
CVMFS_HIDE_MAGIC_XATTRS=yes
CVMFS_FOLLOW_REDIRECTS=yes
CVMFS_SERVER_CACHE_MODE=yes
EOF
}


remove_config_files() {
  local name=$1
  load_repo_config $name

  local apache_conf_file_name="$(get_apache_conf_filename $name)"
  if is_local_upstream $CVMFS_UPSTREAM_STORAGE &&
     has_apache_config_file "$apache_conf_file_name"; then
    remove_apache_config_file "$apache_conf_file_name"
    reload_apache > /dev/null
  fi
  rm -rf /etc/cvmfs/repositories.d/$name
}


create_spool_area_for_new_repository() {
  local name=$1

  # gather repository information from configuration file
  load_repo_config $name
  local spool_dir=$CVMFS_SPOOL_DIR
  local current_scratch_dir="${spool_dir}/scratch/current"
  local wastebin_scratch_dir="${spool_dir}/scratch/wastebin"
  local rdonly_dir="${spool_dir}/rdonly"
  local temp_dir="${spool_dir}/tmp"
  local cache_dir="${spool_dir}/cache"
  local ofs_workdir="${spool_dir}/ofs_workdir"

  mkdir -p /cvmfs/$name          \
           $current_scratch_dir  \
           $wastebin_scratch_dir \
           $rdonly_dir           \
           $temp_dir             \
           $cache_dir || return 1
  if [ x"$CVMFS_UNION_FS_TYPE" = x"overlayfs" ]; then
    mkdir -p $ofs_workdir || return 2
  fi
  chown -R $CVMFS_USER /cvmfs/$name/ $spool_dir/
}


remove_spool_area() {
  local name=$1
  load_repo_config $name
  [ x"$CVMFS_SPOOL_DIR" != x"" ] || return 0
  rm -fR "$CVMFS_SPOOL_DIR"      || return 1
  if [ -d /cvmfs/$name ]; then
    rmdir /cvmfs/$name           || return 2
  fi
}


import_keychain() {
  local name=$1
  local keys_location="$2"
  local cvmfs_user=$3
  local keys="$4"

  local global_key_dir="/etc/cvmfs/keys"
  mkdir -p $global_key_dir || return 1
  for keyfile in $keys; do
    echo -n "importing $keyfile ... "
    if [ ! -f "${global_key_dir}/${keyfile}" ]; then
      cp "${keys_location}/${keyfile}" $global_key_dir || return 2
    fi
    local key_mode=400
    if echo "$keyfile" | grep -vq '.*key$'; then
      key_mode=444
    fi
    chmod $key_mode "${global_key_dir}/${keyfile}"   || return 3
    chown $cvmfs_user "${global_key_dir}/${keyfile}" || return 4
    echo "done"
  done
}


create_repository_storage() {
  local name=$1
  local storage_dir
  load_repo_config $name
  storage_dir=$(get_upstream_config $CVMFS_UPSTREAM_STORAGE)
  create_repository_skeleton $storage_dir $CVMFS_USER > /dev/null
}


setup_and_mount_new_repository() {
  local name=$1
  local http_timeout=15

  # get repository information
  load_repo_config $name
  local rdonly_dir="${CVMFS_SPOOL_DIR}/rdonly"
  local scratch_dir="${CVMFS_SPOOL_DIR}/scratch/current"
  local ofs_workdir="${CVMFS_SPOOL_DIR}/ofs_workdir"

  local selinux_context=""
  if [ x"$CVMFS_UNION_FS_TYPE" = x"overlayfs" ]; then
    echo -n "(overlayfs) "
    cat >> /etc/fstab << EOF
cvmfs2#$name $rdonly_dir fuse allow_other,config=/etc/cvmfs/repositories.d/${name}/client.conf:${CVMFS_SPOOL_DIR}/client.local,cvmfs_suid,noauto 0 0 # added by CernVM-FS for $name
overlay_$name /cvmfs/$name overlay upperdir=${scratch_dir},lowerdir=${rdonly_dir},workdir=$ofs_workdir,noauto,ro 0 0 # added by CernVM-FS for $name
EOF
  else
    echo -n "(aufs) "
    if has_selinux && try_mount_remount_cycle_aufs; then
      selinux_context=",context=\"system_u:object_r:default_t:s0\""
    fi
    cat >> /etc/fstab << EOF
cvmfs2#$name $rdonly_dir fuse allow_other,config=/etc/cvmfs/repositories.d/${name}/client.conf:${CVMFS_SPOOL_DIR}/client.local,cvmfs_suid,noauto 0 0 # added by CernVM-FS for $name
aufs_$name /cvmfs/$name aufs br=${scratch_dir}=rw:${rdonly_dir}=rr,udba=none,noauto,ro$selinux_context 0 0 # added by CernVM-FS for $name
EOF
  fi
  local user_shell="$(get_user_shell $name)"
  $user_shell "touch ${CVMFS_SPOOL_DIR}/client.local"

  # avoid racing against apache
  local waiting=0
  while ! curl -sIf ${CVMFS_STRATUM0}/.cvmfspublished > /dev/null && \
        [ $http_timeout -gt 0 ]; do
    [ $waiting -eq 1 ] || echo -n "waiting for apache... "
    waiting=1
    http_timeout=$(( $http_timeout - 1 ))
    sleep 1
  done
  [ $http_timeout -gt 0 ] || return 1

  mount $rdonly_dir > /dev/null || return 1
  mount /cvmfs/$name
}


unmount_and_teardown_repository() {
  local name=$1
  load_repo_config $name
  sed -i -e "/added by CernVM-FS for ${name}/d" /etc/fstab
  local rw_mnt="/cvmfs/$name"
  local rdonly_mnt="${CVMFS_SPOOL_DIR}/rdonly"
  is_mounted "$rw_mnt"     && ( umount $rw_mnt     || return 1; )
  is_mounted "$rdonly_mnt" && ( umount $rdonly_mnt || return 2; )
  return 0
}


print_new_repository_notice() {
  local name=$1
  local cvmfs_user=$2

  echo "\

Before you can install anything, call \`cvmfs_server transaction\`
to enable write access on your repository. Then install your
software in /cvmfs/$name as user $cvmfs_user.
Once you're happy, publish using \`cvmfs_server publish\`

For client configuration, have a look at 'cvmfs_server info'

If you go for production, backup you software signing keys in /etc/cvmfs/keys/!"
}


################################################################################
#                                                                              #
#                        JSON "API" related functions                          #
#                                                                              #
################################################################################


get_global_info_path() {
  echo "${DEFAULT_LOCAL_STORAGE}/info"
}


get_global_info_v1_path() {
  echo "$(get_global_info_path)/v${LATEST_JSON_INFO_SCHEMA}"
}


_write_info_file() {
  local info_file="${1}.json"
  local info_file_dir="$(get_global_info_v1_path)"
  local info_file_path="${info_file_dir}/${info_file}"
  local tmp_file="${info_file_dir}/${info_file}.txn.$(date +%s)"

  cat - > $tmp_file
  chmod 0644 $tmp_file
  mv -f $tmp_file $info_file_path
  set_selinux_httpd_context_if_needed $info_file_dir
}


_check_info_file() {
  local info_file="${1}.json"
  [ -f "$(get_global_info_v1_path)/${info_file}" ]
}


_available_repos() {
  local filter="$1"
  local repo=""
  local repo_cfg_path="/etc/cvmfs/repositories.d"

  [ $(ls $repo_cfg_path | wc -l) -gt 0 ] || return 0
  for repository in ${repo_cfg_path}/*; do
    repo=$(basename $repository)
    if ( [ x"$filter" = x"" ]                              ) || \
       ( [ x"$filter" = x"stratum0" ] && is_stratum0 $repo ) || \
       ( [ x"$filter" = x"stratum1" ] && is_stratum1 $repo ); then
      echo $repo
    fi
  done
}


_render_repos() {
  local i=$#

  for repo in $@; do
    load_repo_config $repo

    echo '    {'
    echo '      "name"  : "'$CVMFS_REPOSITORY_NAME'",'
    if [ x"$CVMFS_REPOSITORY_NAME" != x"$repo" ]; then
      echo '      "alias" : "'$repo'",'
    fi
    echo '      "url"   : "/cvmfs/'$repo'"'
    echo -n '    }'

    i=$(( $i - 1 ))
    [ $i -gt 0 ] && echo "," || echo ""
  done
}


_render_info_file() {
  echo '{'
  echo '  "schema"       : '$LATEST_JSON_INFO_SCHEMA','
  echo '  "repositories" : ['

  _render_repos $(_available_repos "stratum0")

  echo '  ],'
  echo '  "replicas" : ['

  _render_repos $(_available_repos "stratum1")

  echo '  ]'
  echo '}'
}


has_global_info_path() {
  [ -d $(get_global_info_path) ] && [ -d $(get_global_info_v1_path) ]
}


create_global_info_skeleton() {
  local info_path="$(get_global_info_path)"
  local info_v1_path="$(get_global_info_v1_path)"

  mkdir -p $info_path                               || return 1
  mkdir -p $info_v1_path                            || return 2
  set_selinux_httpd_context_if_needed $info_path    || return 3
  set_selinux_httpd_context_if_needed $info_v1_path || return 4

  _check_info_file "repositories" || echo "{}" | _write_info_file "repositories"
  _check_info_file "meta" || _write_info_file "meta" << EOF
{
  "administrator" : "Your Name",
  "email"         : "you@organisation.org",
  "organisation"  : "Your Organisation",

  "custom" : {
    "_comment" : "Put arbitrary structured data here"
  }
}
EOF
}


update_global_repository_info() {
  # sanity checks
  has_global_info_path || return 1
  is_root              || return 2

  _render_info_file | _write_info_file "repositories"
}


update_global_meta_info() {
  local meta_info_file="$1"
  has_global_info_path || return 1
  is_root              || return 2

  cat "$meta_info_file" | _write_info_file "meta"
}


get_editor() {
  local editor=${EDITOR:=vi}
  if ! which $editor  > /dev/null 2>&1; then
    echo  "Didn't find editor '$editor'." 1>&2
    echo "Consider to use the \$EDITOR environment variable" 1>&2
    exit 1
  fi
  echo $editor
}


check_jq() {
  local has_jq=1
  if ! which jq > /dev/null 2>&1; then
    has_jq=0
    echo 1>&2
    echo "Warning: Didn't find 'jq' on your system. It is your responsibility" 1>&2
    echo "         to produce a valid JSON file." 1>&2
    echo 1>&2
    read -p "  Press any key to continue..." nirvana
  fi
  echo $has_jq
}


validate_json() {
  local json_file="$1"

  if ! which jq > /dev/null 2>&1; then
    return 0 # no jq -> assume JSON is valid
  fi

  jq '.' $json_file 2>&1
}


edit_json_until_valid() {
  local json_file="$1"
  local editor=$(get_editor)
  local has_jq=$(check_jq)

  local retval=0
  while true; do
    $editor $json_file < $(tty) > $(tty) 2>&1
    [ $has_jq -eq 1 ] || break

    local jq_output=""
    local retry=""
    if ! jq_output=$(validate_json $json_file); then
      echo
      echo "Your JSON file is invalid, please check again:"
      echo "$jq_output"
      read -p "Edit again? [y]: " retry
      if [ x"$retry" != x"y" ] && \
         [ x"$retry" != x"Y" ] && \
         [ x"$retry" != x""  ]; then
        retval=1
        break
      fi
    else
      break
    fi
  done

  return $retval
}

create_repometa_skeleton() {
  local json_file="$1"
  cat > "$json_file" << EOF
{
  "administrator" : "Your Name",
  "email"         : "you@organisation.org",
  "organisation"  : "Your Organisation",
  "description"   : "Repository content",
  "recommended-stratum1s" : [ "stratum1 url", "stratum1 url" ],

  "custom" : {
    "_comment" : "Put arbitrary structured data here"
  }
}
EOF
}


################################################################################
#                                                                              #
#                                Sub Commands                                  #
#                                                                              #
################################################################################

_update_geodb_days_since_update() {
  local timestamp=$(date +%s)
  local dbdir=$CVMFS_UPDATEGEO_DIR
  local db_mtime=$(stat --format='%Y' ${dbdir}/${CVMFS_UPDATEGEO_DAT})
  local db_mtime6=$(stat --format='%Y' ${dbdir}/${CVMFS_UPDATEGEO_DAT6})
  if [ "$db_mtime6" -lt "$db_mtime" ]; then
    # take the older of the two
    db_mtime=$db_mtime6
  fi
  local days_since_update=$(( ( $timestamp - $db_mtime ) / 86400 ))
  echo "$days_since_update"
}

_update_geodb_lazy_install_slot() {
  [ "`date +%w`" -eq "$CVMFS_UPDATEGEO_DAY"  ] && \
  [ "`date +%k`" -ge "$CVMFS_UPDATEGEO_HOUR" ]
}

_to_syslog_for_geoip() {
  to_syslog "(GeoIP) $1"
}

_update_geodb_install_1() {
  local retcode=0
  local urlbase="$1"
  local datname="$2"
  local dburl="${urlbase}/${datname}.gz"
  local dbfile="${CVMFS_UPDATEGEO_DIR}/${datname}"
  local download_target=${dbfile}.gz
  local unzip_target=${dbfile}.new

  _to_syslog_for_geoip "started update from $dburl"

  # downloading the GeoIP database file
  if ! curl -sS                  \
            --fail               \
            --connect-timeout 10 \
            --max-time 60        \
            "$dburl" > $download_target 2>/dev/null; then
    echo "failed to download $dburl" >&2
    _to_syslog_for_geoip "failed to download from $dburl"
    rm -f $download_target
    return 1
  fi

  # unzipping the GeoIP database file
  if ! zcat $download_target > $unzip_target 2>/dev/null; then
    echo "failed to unzip $download_target to $unzip_target" >&2
    _to_syslog_for_geoip "failed to unzip $download_target to $unzip_target"
    rm -f $download_target $unzip_target
    return 2
  fi

  # get rid of the zipped GeoIP database
  rm -f $download_target

  # atomically installing the GeoIP database
  if ! mv -f $unzip_target $dbfile; then
    echo "failed to install $dbfile" >&2
    _to_syslog_for_geoip "failed to install $dbfile"
    rm -f $unzip_target
    return 3
  fi

  _to_syslog_for_geoip "successfully updated from $dburl"

  return 0
}

_update_geodb_install() {
  _update_geodb_install_1 $CVMFS_UPDATEGEO_URLBASE $CVMFS_UPDATEGEO_DAT && \
    _update_geodb_install_1 $CVMFS_UPDATEGEO_URLBASE6 $CVMFS_UPDATEGEO_DAT6
}

_update_geodb() {
  local dbdir=$CVMFS_UPDATEGEO_DIR
  local dbfile=$dbdir/$CVMFS_UPDATEGEO_DAT
  local dbfile6=$dbdir/$CVMFS_UPDATEGEO_DAT6
  local lazy=false
  local retcode=0

  # parameter handling
  OPTIND=1
  while getopts "l" option; do
    case $option in
      l)
        lazy=true
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command update-geodb: Unrecognized option: $1"
      ;;
    esac
  done

  # sanity checks
  [ -w "$dbdir"  ]   || { echo "Directory '$dbdir' doesn't exist or is not writable by $(whoami)" >&2; return 1; }
  [ ! -f "$dbfile" ] || [ -w "$dbfile" ] || { echo "GeoIP database '$dbfile' is not writable by $(whoami)" >&2; return 2; }
  [ ! -f "$dbfile6" ] || [ -w "$dbfile6" ] || { echo "GeoIP database '$dbfile6' is not writable by $(whoami)" >&2; return 2; }

  # check if an update/installation needs to be done
  if [ ! -f "$dbfile" ] || [ ! -f "$dbfile6" ]; then
    echo -n "Installing GeoIP Database... "
  elif ! $lazy; then
    echo -n "Updating GeoIP Database... "
  else
    local days_old=$(_update_geodb_days_since_update)
    if [ $days_old -gt $CVMFS_UPDATEGEO_MAXDAYS ]; then
      echo -n "GeoIP Database is very old. Updating... "
    elif [ $days_old -gt $CVMFS_UPDATEGEO_MINDAYS ]; then
      if _update_geodb_lazy_install_slot; then
        echo -n "GeoIP Database is expired. Updating... "
      else
        echo "GeoIP Database is expired, but waiting for install time slot."
        return 0
      fi
    else
      echo "GeoIP Database is up to date ($days_old days old). Nothing to do."
      return 0
    fi
  fi

  # at this point the database needs to be installed or updated
  _update_geodb_install && echo "done" || { echo "fail"; return 3; }
}

cvmfs_server_update_geodb() {
  _update_geodb $@
}

################################################################################


cvmfs_server_alterfs() {
  local master_replica=-1
  local name

  # parameter handling
  OPTIND=1
  while getopts "m:" option; do
    case $option in
      m)
        if [ x$OPTARG = "xon" ]; then
          master_replica=1
        elif [ x$OPTARG = "xoff" ]; then
          master_replica=0
        else
          usage "Command alterfs: parameter -m expects 'on' or 'off'"
        fi
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command alterfs: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"
  [ $master_replica -ne -1 ] || usage "Command alterfs: What should I change?"
  is_root || die "Only root can alter a repository"

  # gather repository information
  load_repo_config $name
  local temp_dir="${CVMFS_SPOOL_DIR}/tmp"

  # do what you've been asked for
  local success=1
  if is_master_replica $name && [ $master_replica -eq 0 ]; then
    echo -n "Disallowing Replication of this Repository... "
    __swissknife remove -o ".cvmfs_master_replica" -r $CVMFS_UPSTREAM_STORAGE > /dev/null || success=0
    if [ $success -ne 1 ]; then
      echo "fail!"
      return 1
    else
      echo "done"
    fi
  elif ! is_master_replica $name && [ $master_replica -eq 1 ]; then
    echo -n "Allowing Replication of this Repository... "
    local master_replica="${temp_dir}/.cvmfs_master_replica"
    touch $master_replica
    __swissknife upload -i $master_replica -o $(basename $master_replica) -r $CVMFS_UPSTREAM_STORAGE > /dev/null || success=0
    if [ $success -ne 1 ]; then
      echo "fail!"
      return 1
    else
      echo "done"
    fi
    rm -f $master_replica
  fi
}


################################################################################


cvmfs_server_mkfs() {
  local name
  local stratum0
  local upstream
  local owner
  local replicable=1
  local volatile_content=0
  local autotagging=true
  local auto_tag_timespan=
  local unionfs
  local hash_algo
  local compression_alg
  local garbage_collectable=false
  local s3_config=""
  local keys_import_location
  local external_data=false

  local configure_apache=1
  local voms_authz=""

  # parameter handling
  OPTIND=1
  while getopts "Xw:u:o:mf:vgG:a:zs:k:pV:Z:" option; do
    case $option in
      X)
        external_data=true
      ;;
      w)
        stratum0=$OPTARG
      ;;
      u)
        upstream=$OPTARG
      ;;
      o)
        owner=$OPTARG
      ;;
      m)
        replicable=1
      ;;
      f)
        unionfs=$OPTARG
      ;;
      v)
        volatile_content=1
      ;;
      g)
        autotagging=false
      ;;
      G)
        auto_tag_timespan="$OPTARG"
      ;;
      a)
        hash_algo=$OPTARG
      ;;
      z)
        garbage_collectable=true
      ;;
      s)
        s3_config=$OPTARG
      ;;
      k)
        keys_import_location=$OPTARG
      ;;
      Z)
        compression_alg=$OPTARG
      ;;
      p)
        configure_apache=0
      ;;
      V)
        voms_authz=$OPTARG
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command mkfs: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count 1 $#
  name=$(get_repository_name $1)

  # default values
  [ x"$unionfs"   = x"" ] && unionfs="$(get_available_union_fs)"
  [ x"$hash_algo" = x"" ] && hash_algo=sha1
  [ x"$compression_alg" = x"" ] && compression_alg=default

  # upstream generation (defaults to local upstream)
  if [ x"$upstream" = x"" ]; then
    if [ x"$s3_config" != x"" ]; then
      upstream=$(make_s3_upstream $name $s3_config)
    else
      upstream=$(make_local_upstream $name)
    fi
  fi

  # stratum0 URL generation (defaults to local URL)
  if [ x"$s3_config" != x"" ]; then
    [ x"$stratum0" = x"" ] && die "Please specify the HTTP-URL for S3 (add option -w)"
    stratum0=$(mangle_s3_cvmfs_url $name "$stratum0")
  elif [ x"$stratum0" = x"" ]; then
    stratum0="$(mangle_local_cvmfs_url $name)"
  fi

  # sanity checks
  check_repository_existence $name  && die "The repository $name already exists"
  is_root                           || die "Only root can create a new repository"
  check_upstream_validity $upstream
  if [ $unionfs = "overlayfs" ]; then
    check_overlayfs                 || die "overlayfs kernel module missing"
    check_overlayfs_version         || die "Your version of OverlayFS is not supported"
    echo "Warning: CernVM-FS filesystems using overlayfs may not enforce hard link semantics during publishing."
  else
    check_aufs                      || die "aufs kernel module missing"
  fi
  check_cvmfs2_client               || die "cvmfs client missing"
  check_autofs_on_cvmfs             && die "Autofs on /cvmfs has to be disabled"
  lower_hardlink_restrictions
  ensure_swissknife_suid $unionfs   || die "Need CAP_SYS_ADMIN for cvmfs_swissknife"
  if is_local_upstream $upstream; then
    check_apache                    || die "Apache must be installed and running"
    ensure_enabled_apache_modules
  fi
  if [ "x$auto_tag_timespan" != "x" ]; then
    date --date "$auto_tag_timespan" +%s >/dev/null 2>&1 || die "Auto tags time span cannot be parsed"
    [ x"$autotagging" = x"false" ] &&
      echo "Warning: auto tags time span set but auto tagging turned off" || true
  fi

  # check if the keychain for the repository to create is already in place
  local keys_location="/etc/cvmfs/keys"
  mkdir -p $keys_location
  local keys="${name}.masterkey ${name}.key ${name}.crt ${name}.pub"
  local keys_are_there=0
  for k in $keys; do
    if [ -f "${keys_location}/${k}" ]; then
      keys_are_there=1
      break
    fi
  done
  if [ $keys_are_there -eq 1 ]; then
    # just import the keys that are already there if they do not overwrite existing keys
    if [ x"$keys_import_location" != x""               ] && \
       [ x"$keys_import_location" != x"$keys_location" ]; then
      die "Importing keys from '$keys_import_location' would overwrite keys in '$keys_location'"
    fi
    keys_import_location=$keys_location
  fi

  # repository owner dialog
  local cvmfs_user=$(get_cvmfs_owner $name $owner)
  check_user $cvmfs_user || die "No user $cvmfs_user"

  # GC and auto-tag warning
  if [ x"$autotagging" = x"true" ] && [ x"$auto_tag_timespan" = "x" ] && [ x"$garbage_collectable" = x"true" ]; then
    echo "Note: Autotagging all revisions impedes garbage collection"
  fi

  # create system-wide configuration
  echo -n "Creating Configuration Files... "
  create_config_files_for_new_repository "$name"                \
                                         "$upstream"            \
                                         "$stratum0"            \
                                         "$cvmfs_user"          \
                                         "$unionfs"             \
                                         "$hash_algo"           \
                                         "$autotagging"         \
                                         "$garbage_collectable" \
                                         "$configure_apache"    \
                                         "$compression_alg"     \
                                         "$external_data"       \
                                         "$voms_authz"          \
                                         "$auto_tag_timespan" || die "fail"
  echo "done"

  # create or import security keys and certificates
  if [ x"$keys_import_location" = x"" ]; then
    echo -n "Creating CernVM-FS Master Key and Self-Signed Certificate... "
    create_master_key $name $cvmfs_user || die "fail (master key)"
    create_cert $name $cvmfs_user       || die "fail (certificate)"
    echo "done"
  else
    echo -n "Importing CernVM-FS Master Key and Certificate from '$keys_import_location'... "
    import_keychain $name "$keys_import_location" $cvmfs_user "$keys" > /dev/null || die "fail!"
    echo "done"
  fi

  # create spool area and mountpoints
  echo -n "Creating CernVM-FS Server Infrastructure... "
  create_spool_area_for_new_repository $name || die "fail"
  echo "done"

  # create storage area
  if is_local_upstream $upstream; then
    echo -n "Creating Backend Storage... "
    create_global_info_skeleton     || die "fail"
    create_repository_storage $name || die "fail"
    echo "done"
  fi

  # get information about new repository
  load_repo_config $name
  local temp_dir="${CVMFS_SPOOL_DIR}/tmp"
  local rdonly_dir="${CVMFS_SPOOL_DIR}/rdonly"
  local scratch_dir="${CVMFS_SPOOL_DIR}/scratch/current"

  echo -n "Creating Initial Repository... "
  create_whitelist $name $cvmfs_user $upstream $temp_dir > /dev/null
  local repoinfo_file=${temp_dir}/new_repoinfo
  touch $repoinfo_file
  create_repometa_skeleton $repoinfo_file
  sync
  if is_local_upstream $upstream && [ $configure_apache -eq 1 ]; then
    reload_apache > /dev/null
  fi

  local volatile_opt=
  if [ $volatile_content -eq 1 ]; then
    volatile_opt="-v"
    echo -n "(repository flagged volatile)... "
  fi
  local user_shell="$(get_user_shell $name)"
  local create_cmd="$(__swissknife_cmd) create  \
    -t $temp_dir                                \
    -r $upstream                                \
    -n $name                                    \
    -a $hash_algo $volatile_opt                 \
    -o ${temp_dir}/new_manifest                 \
    -R $(get_reflog_checksum $name)"
  if $garbage_collectable; then
    create_cmd="$create_cmd -z"
  fi
  if [ "x$voms_authz" != "x" ]; then
    echo -n "(repository will be accessible with VOMS credentials $voms_authz)... "
    create_cmd="$create_cmd -V $voms_authz"
  fi
  $user_shell "$create_cmd" > /dev/null                       || die "fail! (cannot init repo)"
  sign_manifest $name ${temp_dir}/new_manifest $repoinfo_file || die "fail! (cannot sign repo)"
  echo "done"

  echo -n "Mounting CernVM-FS Storage... "
  setup_and_mount_new_repository $name || die "fail"
  echo "done"

  if [ $replicable -eq 1 ]; then
    cvmfs_server_alterfs -m on $name
  fi

  health_check $name || die "fail! (health check after mount)"

  echo -n "Initial commit... "
  cvmfs_server_transaction $name > /dev/null || die "fail (transaction)"
  echo "New CernVM-FS repository for $name" > /cvmfs/${name}/new_repository
  chown $cvmfs_user /cvmfs/${name}/new_repository
  cvmfs_server_publish $name > /dev/null || die "fail (publish)"
  # When publishing an external repository, it is the user's responsibility to
  # stage the actual data files to the web server - not the publication function.
  # Hence, the following is guaranteed to not work.
  if [ $external_data = "false" ]; then
    cat $rdonly_dir/new_repository || die "fail (finish)"
  fi

  echo -n "Updating global JSON information... "
  update_global_repository_info && echo "done" || echo "fail"

  print_new_repository_notice $name $cvmfs_user
}


################################################################################


cvmfs_server_add_replica() {
  local name
  local alias_name
  local stratum0
  local stratum1_url
  local public_key
  local upstream
  local owner
  local silence_httpd_warning=0
  local configure_apache=1
  local enable_auto_gc=0
  local s3_config

  # optional parameter handling
  OPTIND=1
  while getopts "o:u:n:w:azs:p" option
  do
    case $option in
      u)
        upstream=$OPTARG
      ;;
      o)
        owner=$OPTARG
      ;;
      n)
        alias_name=$OPTARG
      ;;
      w)
        stratum1_url=$OPTARG
      ;;
      a)
        silence_httpd_warning=1
      ;;
      z)
        enable_auto_gc=1
      ;;
      s)
        s3_config=$OPTARG
      ;;
      p)
        configure_apache=0
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command add-replica: Unrecognized option: $1"
      ;;
    esac
  done

   # get stratum0 url and path of public key
  shift $(($OPTIND-1))
  check_parameter_count 2 $#

  stratum0=$1
  public_key=$2

  # get the name of the repository pointed to by $stratum0
  name=$(get_repo_info_from_url $stratum0 -L -n) || die "Failed to access Stratum0 repository at $stratum0"
  name=$(get_repo_info_from_url $stratum0    -n) || die "Failed to access Stratum0 repository at $stratum0"
  if [ x$alias_name = x"" ]; then
    alias_name=$name
  else
    alias_name=$(get_repository_name $alias_name)
  fi

  # sanity checks
  is_master_replica $stratum0 || die "The repository URL $stratum0 does not point to a replicable master copy of $name"
  if check_repository_existence $alias_name; then
    if is_stratum0 $alias_name; then
      die "Repository $alias_name already exists as a Stratum0 repository.\nUse -n to create an aliased Stratum1 replica for $name on this machine."
    else
      die "There is already a Stratum1 repository $alias_name"
    fi
  fi

  # upstream generation (defaults to local upstream)
  if [ x"$upstream" = x"" ]; then
    if [ x"$s3_config" != x"" ]; then
      upstream=$(make_s3_upstream $alias_name $s3_config)
    else
      upstream=$(make_local_upstream $alias_name)
    fi
  fi

  # stratum1 URL generation (defaults to local URL)
  local stratum1=""
  if [ x"$s3_config" != x"" ]; then
    [ x"$stratum1_url" = x"" ] && die "Please specify the HTTP-URL for S3 (add option -w)"
    stratum1=$(mangle_s3_cvmfs_url $alias_name "$stratum1_url")
  elif [ x"$stratum1_url" = x"" ]; then
    stratum1="$(mangle_local_cvmfs_url $alias_name)"
  else
    stratum1="$stratum1_url"
  fi

  # additional configuration
  local cvmfs_user=$(get_cvmfs_owner $alias_name $owner)
  local spool_dir="/var/spool/cvmfs/${alias_name}"
  local temp_dir="${spool_dir}/tmp"
  local storage_dir=""
  is_local_upstream $upstream && storage_dir=$(get_upstream_config $upstream)

  # additional sanity checks
  is_root || die "Only root can create a new repository"
  check_user $cvmfs_user || die "No user $cvmfs_user"
  check_upstream_validity $upstream
  if is_local_upstream $upstream; then
    if [ $silence_httpd_warning -eq 0 ]; then
      check_apache || die "Apache must be installed and running"
      check_wsgi_module
      if [ x"$cvmfs_user" != x"root" ]; then
        echo "NOTE: If snapshot is not run regularly as root, the GeoIP database will not be updated."
        echo "      You have three options:"
        echo "      1. chown -R $CVMFS_UPDATEGEO_DIR accordingly OR"
        echo "      2. run update-geodb monthly as root OR"
        echo "      3. chown -R $CVMFS_UPDATEGEO_DIR to a dedicated"
        echo "         user ID and run update-geodb monthly as that user"
      fi
    else
      check_apache || echo "Warning: Apache is needed to access this CVMFS replication"
    fi
  fi

  echo -n "Creating Configuration Files... "
  mkdir -p /etc/cvmfs/repositories.d/${alias_name}
  cat > /etc/cvmfs/repositories.d/${alias_name}/server.conf << EOF
# Created by cvmfs_server.
CVMFS_CREATOR_VERSION=$(cvmfs_version_string)
CVMFS_REPOSITORY_NAME=$name
CVMFS_REPOSITORY_TYPE=stratum1
CVMFS_USER=$cvmfs_user
CVMFS_SPOOL_DIR=$spool_dir
CVMFS_STRATUM0=$stratum0
CVMFS_STRATUM1=$stratum1
CVMFS_UPSTREAM_STORAGE=$upstream
EOF
  cat > /etc/cvmfs/repositories.d/${alias_name}/replica.conf << EOF
# Created by cvmfs_server.
CVMFS_NUM_WORKERS=16
CVMFS_PUBLIC_KEY=$public_key
CVMFS_HTTP_TIMEOUT=10
CVMFS_HTTP_RETRIES=3
EOF

  # append GC specific configuration
  if [ $enable_auto_gc != 0 ]; then
    cat >> /etc/cvmfs/repositories.d/${alias_name}/server.conf << EOF
CVMFS_AUTO_GC=true
EOF
  fi

  if is_local_upstream $upstream && [ $configure_apache -eq 1 ]; then
    create_apache_config_for_endpoint $alias_name $storage_dir "with wsgi"
    create_apache_config_for_global_info
    reload_apache > /dev/null
  fi
  echo "done"

  if is_local_upstream $upstream; then
    _update_geodb -l
    create_global_info_skeleton

    echo -n "Create CernVM-FS Storage... "
    mkdir -p $storage_dir
    create_repository_skeleton $storage_dir $cvmfs_user > /dev/null
    echo "done"
  fi

  echo -n "Creating CernVM-FS Server Infrastructure... "
  mkdir -p $spool_dir                       || die "fail (mkdir spool)"
  if is_local_upstream $upstream; then
    ln -s ${storage_dir}/data/txn $temp_dir || die "fail (ln -s)"
  else
    mkdir -p $temp_dir                      || die "fail (mkdir temp)"
  fi
  chown -R $cvmfs_user $spool_dir           || die "fail (chown)"
  echo "done"

  echo -n "Updating global JSON information... "
  update_global_repository_info && echo "done" || echo "fail"

  echo "\

Use 'cvmfs_server snapshot' to replicate $alias_name.
Make sure to install the repository public key in /etc/cvmfs/keys/
You might have to add the key in /etc/cvmfs/repositories.d/${alias_name}/replica.conf"
}


################################################################################


IMPORT_DESASTER_REPO_NAME=""
IMPORT_DESASTER_MANIFEST_BACKUP=""
IMPORT_DESASTER_MANIFEST_SIGNED=0
_import_desaster_cleanup() {
  local name="$IMPORT_DESASTER_REPO_NAME"
  if [ x"$name" = x"" ]; then
    return 0
  fi

  unmount_and_teardown_repository $name
  remove_spool_area               $name
  remove_config_files             $name

  if [ $IMPORT_DESASTER_MANIFEST_SIGNED -ne 0 ] && \
     [ x$IMPORT_DESASTER_MANIFEST_BACKUP != x"" ]; then
    echo "Manifest was overwritten. If needed here is a backup: $IMPORT_DESASTER_MANIFEST_BACKUP"
  fi
}


cvmfs_server_import() {
  local name
  local stratum0
  local keys_location="/etc/cvmfs/keys"
  local upstream
  local owner
  local file_ownership
  local is_legacy=0
  local show_statistics=0
  local replicable=0
  local chown_backend=0
  local unionfs=
  local recreate_whitelist=0
  local configure_apache=1
  local recreate_repo_key=0

  # parameter handling
  OPTIND=1
  while getopts "w:o:c:u:k:lsmgf:rpt" option; do
    case $option in
      w)
        stratum0=$OPTARG
      ;;
      o)
        owner=$OPTARG
      ;;
      c)
        file_ownership=$OPTARG
      ;;
      u)
        upstream=$OPTARG
      ;;
      k)
        keys_location=$OPTARG
      ;;
      l)
        is_legacy=1
      ;;
      s)
        show_statistics=1
      ;;
      m)
        replicable=1
      ;;
      g)
        chown_backend=1
      ;;
      f)
        unionfs=$OPTARG
      ;;
      r)
        recreate_whitelist=1
      ;;
      p)
        configure_apache=0
      ;;
      t)
        recreate_repo_key=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command import: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count 1 $#
  name=$(get_repository_name $1)

  # default values
  [ x"$stratum0" = x ] && stratum0="$(mangle_local_cvmfs_url $name)"
  [ x"$upstream" = x ] && upstream=$(make_local_upstream $name)
  [ x"$unionfs"  = x ] && unionfs="$(get_available_union_fs)"

  local private_key="${name}.key"
  local master_key="${name}.masterkey"
  local certificate="${name}.crt"
  local public_key="${name}.pub"

  # sanity checks
  check_repository_existence $name  && die "The repository $name already exists"
  is_root                           || die "Only root can create a new repository"
  check_upstream_validity $upstream
  check_cvmfs2_client               || die "cvmfs client missing"
  check_autofs_on_cvmfs             && die "Autofs on /cvmfs has to be disabled"
  check_apache                      || die "Apache must be installed and running"
  is_local_upstream $upstream       || die "Import only works locally for the moment"
  ensure_swissknife_suid $unionfs   || die "Need CAP_SYS_ADMIN for cvmfs_swissknife"
  lower_hardlink_restrictions
  ensure_enabled_apache_modules
  [ x"$keys_location" = "x" ] && die "Please provide the location of the repository security keys (-k)"

  if [ $unionfs = "overlayfs" ]; then
    check_overlayfs                 || die "overlayfs kernel module missing"
    check_overlayfs_version         || die "Your version of OverlayFS is not supported"
    echo "Warning: CernVM-FS filesystems using overlayfs may not enforce hard link semantics during publishing."
  else
    check_aufs                      || die "aufs kernel module missing"
  fi

  # repository owner dialog
  local cvmfs_user=$(get_cvmfs_owner $name $owner)
  check_user $cvmfs_user || die "No user $cvmfs_user"
  [ x"$file_ownership" = x ] && file_ownership="$(id -u $cvmfs_user):$(id -g $cvmfs_user)"
  echo $file_ownership | grep -q "^[0-9][0-9]*:[0-9][0-9]*$" || die "Unrecognized file ownership: $file_ownership | expected: <uid>:<gid>"
  local cvmfs_uid=$(echo $file_ownership | cut -d: -f1)
  local cvmfs_gid=$(echo $file_ownership | cut -d: -f2)

  # investigate the given repository storage for sanity
  local storage_location=$(get_upstream_config $upstream)
  local needed_items="${storage_location}                 \
                      ${storage_location}/.cvmfspublished \
                      ${storage_location}/data            \
                      ${storage_location}/data/txn"
  local i=0
  while [ $i -lt 256 ]; do
    needed_items="$needed_items ${storage_location}/data/$(printf "%02x" $i)"
    i=$(($i+1))
  done
  for item in $needed_items; do
    [ -e $item ] || die "$item missing"
    [ $chown_backend -ne 0 ] || [ x"$cvmfs_user" = x"$(stat -c%U $item)" ] || die "$item not owned by $cvmfs_user"
  done

  # check availability of repository signing key and certificate
  local keys="$public_key"
  if [ $recreate_repo_key -eq 0 ]; then
    if [ ! -f ${keys_location}/${private_key} ] || \
       [ ! -f ${keys_location}/${certificate} ]; then
      die "repository signing key or certificate not found (use -t maybe?)"
    fi
    keys="$keys $private_key $certificate"
  else
    [ $recreate_whitelist -ne 0 ] || die "using -t implies whitelist recreation (use -r maybe?)"
  fi

  # check whitelist expiry date
  if [ $recreate_whitelist -eq 0 ]; then
    [ -f "${storage_location}/.cvmfswhitelist" ] || die "didn't find ${storage_location}/.cvmfswhitelist"
    local expiry=$(get_expiry_from_string "$(cat "${storage_location}/.cvmfswhitelist")")
    [ $expiry -gt 0 ] || die "Repository whitelist expired (use -r maybe?)"
  else
    [ -f ${keys_location}/${master_key} ] || die "no master key found for whitelist recreation"
  fi

  # set up desaster cleanup
  IMPORT_DESASTER_REPO_NAME="$name"
  trap _import_desaster_cleanup EXIT HUP INT QUIT TERM

  # create the configuration for the new repository
  # TODO(jblomer): make a better guess for hash and compression algorithm (see
  # also reflog creation)
  echo -n "Creating configuration files... "
  create_config_files_for_new_repository "$name"             \
                                         "$upstream"         \
                                         "$stratum0"         \
                                         "$cvmfs_user"       \
                                         "$unionfs"          \
                                         "sha1"              \
                                         "true"              \
                                         "false"             \
                                         "$configure_apache" \
                                         "default"           \
                                         "false"             \
                                         ""                  \
                                         "" || die "fail!"
  echo "done"

  # import the old repository security keys
  echo -n "Importing the given key files... "
  if [ -f ${keys_location}/${master_key} ]; then
    keys="$keys $master_key"
  fi
  import_keychain $name "$keys_location" $cvmfs_user "$keys" > /dev/null || die "fail!"
  echo "done"

  # create storage
  echo -n "Creating CernVM-FS Repository Infrastructure... "
  create_spool_area_for_new_repository $name               || die "fail!"
  [ $configure_apache -eq 0 ] || reload_apache > /dev/null || die "fail!"
  echo "done"

  # create reflog checksum
  if [ -f ${storage_location}/.cvmfsreflog ]; then
    echo -n "Re-creating reflog content hash... "
    local reflog_hash=$(cat ${storage_location}/.cvmfsreflog | cvmfs_swissknife hash -a sha1)
    echo -n $reflog_hash > "${CVMFS_SPOOL_DIR}/reflog.chksum"
    chown $CVMFS_USER "${CVMFS_SPOOL_DIR}/reflog.chksum"
    echo $reflog_hash
  fi

  # load repository configuration file
  load_repo_config $name
  local temp_dir="${CVMFS_SPOOL_DIR}/tmp"

  # import storage location
  if [ $chown_backend -ne 0 ]; then
    echo -n "Importing CernVM-FS storage... "
    chown -R $cvmfs_user $storage_location || die "fail!"
    set_selinux_httpd_context_if_needed $storage_location || die "fail!"
    echo "done"
  fi

  # creating a new repository signing key if requested
  if [ $recreate_repo_key -ne 0 ]; then
    echo -n "Creating new repository signing key... "
    local manifest_url="${CVMFS_STRATUM0}/.cvmfspublished"
    local unsigned_manifest="${CVMFS_SPOOL_DIR}/tmp/unsigned_manifest"
    create_cert $name $CVMFS_USER                     || die "fail (certificate creation)!"
    get_item $name $manifest_url | \
      strip_manifest_signature - > $unsigned_manifest || die "fail (manifest download)!"
    chown $CVMFS_USER $unsigned_manifest              || die "fail (manifest chown)!"
    sign_manifest $name $unsigned_manifest            || die "fail (manifest resign)!"
    echo "done"
  fi

  # recreate whitelist if requested
  if [ $recreate_whitelist -ne 0 ]; then
    echo -n "Recreating whitelist... "
    create_whitelist $name $CVMFS_USER               \
                           ${CVMFS_UPSTREAM_STORAGE} \
                           ${CVMFS_SPOOL_DIR}/tmp > /dev/null || die "fail!"
    echo "done"
  fi

  # migrate old catalogs
  if [ $is_legacy -ne 0 ]; then
    echo "Migrating old catalogs (may take a while)... "
    local new_manifest="${temp_dir}/new_manifest"
    local statistics_flag
    if [ $show_statistics -ne 0 ]; then
      statistics_flag="-s"
    fi
    IMPORT_DESASTER_MANIFEST_BACKUP="${storage_location}/.cvmfspublished.bak"
    cp ${storage_location}/.cvmfspublished \
       $IMPORT_DESASTER_MANIFEST_BACKUP || die "fail! (cannot backup .cvmfspublished)"
    __swissknife migrate               \
      -v "2.0.x"                       \
      -r $storage_location             \
      -n $name                         \
      -u $upstream                     \
      -t $temp_dir                     \
      -k "/etc/cvmfs/keys/$public_key" \
      -o $new_manifest                 \
      -p $cvmfs_uid                    \
      -g $cvmfs_gid                    \
      -f                               \
      $statistics_flag              || die "fail! (migration)"
    chown $cvmfs_user $new_manifest || die "fail! (chown manifest)"

    # sign new (migrated) repository revision
    echo -n "Signing newly imported Repository... "
    local user_shell="$(get_user_shell $name)"
    sign_manifest $name $new_manifest || die "fail! (cannot sign repo)"
    IMPORT_DESASTER_MANIFEST_SIGNED=1
    echo "done"
  fi

  # do final setup
  echo -n "Mounting CernVM-FS Storage... "
  setup_and_mount_new_repository $name || die "fail!"
  echo "done"

  # the .cvmfsdirtab semantics might need an update
  if [ $is_legacy -ne 0 ] && [ -f /cvmfs/${name}/.cvmfsdirtab ]; then
    echo -n "Migrating .cvmfsdirtab... "
    migrate_legacy_dirtab $name || die "fail!"
    echo "done"
  fi

  # make stratum0 repository replicable if requested
  if [ $replicable -eq 1 ]; then
    cvmfs_server_alterfs -m on $name
  fi

  echo -n "Updating global JSON information... "
  update_global_repository_info && echo "done" || echo "fail"

  # reset trap and finish
  trap - EXIT HUP INT QUIT TERM
  print_new_repository_notice $name $cvmfs_user

  # print warning if OverlayFS is used for repository management
  if [ x"$CVMFS_UNION_FS_TYPE" = x"overlayfs" ]; then
    echo ""
    echo "WARNING: You are using OverlayFS which cannot handle hard links."
    echo "         If the imported repository '${name}' used to be based on"
    echo "         AUFS, please run the following command NOW to remove hard"
    echo "         links from the catalogs:"
    echo ""
    echo "    cvmfs_server eliminate-hardlinks ${name}"
    echo ""
  fi
}


################################################################################


cvmfs_server_rmfs() {
  local names
  local force=0
  local preserve_data=0
  local retcode=0

  # optional parameter handling
  OPTIND=1
  while getopts "fp" option
  do
    case $option in
      f)
        force=1
      ;;
      p)
        preserve_data=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command rmfs: Unrecognized option: $1"
      ;;
    esac
  done

  # sanity checks
  is_root               || die "Only root can remove a repository"
  check_autofs_on_cvmfs && die "Autofs on /cvmfs has to be disabled"
  ensure_enabled_apache_modules

  # get repository names
  shift $(($OPTIND-1))
  check_parameter_count_for_multiple_repositories $#
  names=$(get_or_guess_multiple_repository_names $@)
  check_multiple_repository_existence "$names"

  for name in $names; do

    # better ask the user again!
    if [ $force -ne 1 ]; then
      local reply
      local question=""
      if [ $preserve_data -eq 0 ]; then
        question="You are about to WIPE OUT THE CERNVM-FS REPOSITORY ${name} INCLUDING SIGNING KEYS!"
      else
        question="You are about to REMOVE THE CERNVM-FS REPOSITORY INFRASTRUCTURE for ${name}!"
      fi

      read -p "${question}  Are you sure (y/N)? " reply
      if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
        continue
      fi
    fi

    # get information about repository
    load_repo_config $name

    # check if repository is compatible to the installed CernVM-FS version
    check_repository_compatibility $name

    # sanity checks
    [ x"$CVMFS_SPOOL_DIR"        = x ] && { echo "Spool directory for $name is undefined";  retcode=1; continue; }
    [ x"$CVMFS_UPSTREAM_STORAGE" = x ] && { echo "Upstream storage for $name is undefined"; retcode=1; continue; }
    [ x"$CVMFS_REPOSITORY_TYPE"  = x ] && { echo "Repository type for $name is undefined";  retcode=1; continue; }

    # do it!
    if [ "$CVMFS_REPOSITORY_TYPE" = "stratum0" ]; then
      echo -n "Unmounting CernVM-FS Area... "
      unmount_and_teardown_repository $name || die "fail"
      echo "done"
    fi

    echo -n "Removing Spool Area... "
    remove_spool_area $name
    echo done

    echo -n "Removing Configuration... "
    remove_config_files $name || die "fail"
    echo "done"

    if [ $preserve_data -eq 0 ] && \
       is_local_upstream $CVMFS_UPSTREAM_STORAGE; then
      echo -n "Removing Repository Storage... "
      local storage_dir="$(get_upstream_config $CVMFS_UPSTREAM_STORAGE)"
      if [ x"$storage_dir" != x"" ]; then
        rm -fR "$storage_dir" || die "fail"
      fi
      echo "done"
    fi

    if [ $preserve_data -eq 0 ] && \
       [ "$CVMFS_REPOSITORY_TYPE" = stratum0 ]; then
      echo -n "Removing Keys and Certificate... "
      rm -f /etc/cvmfs/keys/$name.masterkey \
            /etc/cvmfs/keys/$name.pub       \
            /etc/cvmfs/keys/$name.key       \
            /etc/cvmfs/keys/$name.crt || die "fail"
      echo "done"
    fi

    echo -n "Updating global JSON information... "
    update_global_repository_info && echo "done" || echo "fail"

    echo "CernVM-FS repository $name wiped out!"

  done

  return $retcode
}


################################################################################


cvmfs_server_resign() {
  local names
  local retcode=0

  # get repository names
  check_parameter_count_for_multiple_repositories $#
  names=$(get_or_guess_multiple_repository_names $@)
  check_multiple_repository_existence "$names"

  # sanity checks
  is_root || die "Only root can resign repositories"

  for name in $names; do

    # sanity checks
    is_stratum0 $name  || { echo "Repository $name is not a stratum 0 repository"; retcode=1; continue; }
    health_check $name || { echo "Repository $name is not healthy"; retcode=1; continue; }

    # get repository information
    load_repo_config $name

    # check if repository is compatible to the installed CernVM-FS version
    check_repository_compatibility $name

    # do it!
    create_whitelist $name $CVMFS_USER \
        ${CVMFS_UPSTREAM_STORAGE} \
        ${CVMFS_SPOOL_DIR}/tmp

  done

  return $retcode
}


################################################################################


cvmfs_server_list_catalogs() {
  local name
  local param_list="-t"

  # optional parameter handling
  OPTIND=1
  while getopts "sehx" option
  do
    case $option in
      s)
        param_list="$param_list -s"
      ;;
      e)
        param_list="$param_list -e"
      ;;
      h)
        param_list="$param_list -d"
      ;;
      x)
        param_list=$(echo "$param_list" | sed 's/-t\s\?//')
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command list-catalogs: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"

  # get repository information
  load_repo_config $name

  # more sanity checks
  is_owner_or_root $name || die "Permission denied: Repository $name is owned by $CVMFS_USER"
  health_check     $name || die "Repository $name is not healthy"

  # check if repository is compatible to the installed CernVM-FS version
  check_repository_compatibility $name

  # do it!
  local user_shell="$(get_user_shell $name)"
  local lsrepo_cmd
  lsrepo_cmd="$(__swissknife_cmd dbg) lsrepo     \
                       -r $CVMFS_STRATUM0        \
                       -n $CVMFS_REPOSITORY_NAME \
                       -k $CVMFS_PUBLIC_KEY      \
                       -l ${CVMFS_SPOOL_DIR}/tmp \
                       $param_list"
  $user_shell "$lsrepo_cmd"
}


################################################################################


cvmfs_server_info() {
  local name
  local stratum0

  # get repository name
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"
  is_stratum0 $name || die "This is not a stratum 0 repository"

  # get repository information
  load_repo_config $name
  stratum0=$CVMFS_STRATUM0

  # do it!
  echo "Repository name: $name"
  echo "Created by CernVM-FS $(mangle_version_string $(repository_creator_version $name))"
  local replication_allowed="yes"
  is_master_replica $name || replication_allowed="no"
  echo "Stratum1 Replication Allowed: $replication_allowed"
  local expire_countdown=$(get_expiry $name $stratum0)
  if [ $expire_countdown -le 0 ]; then
    echo "Whitelist is expired"
  else
    local valid_time=$(( $expire_countdown/(3600*24) ))
    echo "Whitelist is valid for another $valid_time days"
  fi
  echo

  echo "\
Client configuration:
Add $name to CVMFS_REPOSITORIES in /etc/cvmfs/default.local
Create /etc/cvmfs/config.d/${name}.conf and set
  CVMFS_SERVER_URL=$stratum0
  CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${name}.pub
Copy /etc/cvmfs/keys/${name}.pub to the client"
}


################################################################################


cvmfs_server_tag() {
  local name
  local tag_name=""
  local action_add=0
  local add_tag_channel
  local add_tag_description
  local add_tag_root_hash
  local action_remove=0
  local tag_names=""
  local remove_tag_force=0
  local action_inspect=0
  local action_list=0
  local machine_readable=0
  local silence_warnings=0

  # optional parameter handling
  OPTIND=1
  while getopts "a:c:m:h:r:flxi:" option
  do
    case $option in
      a)
        tag_name="$OPTARG"
        action_add=1
      ;;
      c)
        add_tag_channel=$OPTARG
        ;;
      m)
        add_tag_description="$OPTARG"
        ;;
      h)
        add_tag_root_hash=$OPTARG
        ;;
      r)
        [ -z "$tag_names" ]      \
          && tag_names="$OPTARG" \
          || tag_names="$tag_names $OPTARG"
        action_remove=1
        ;;
      f)
        remove_tag_force=1
        ;;
      l)
        action_list=1
        ;;
      x)
        machine_readable=1
        silence_warnings=1
        ;;
      i)
        tag_name="$OPTARG"
        action_inspect=1
        ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command tag: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # check for ambiguous action requests
  local actions=$(( $action_remove+$action_list+$action_add+$action_inspect ))
  [ $actions -gt 0 ] || { action_list=1; actions=$(( $actions + 1 )); } # listing is the default action
  [ $actions -eq 1 ] || die "Ambiguous parameters. Please either add, remove, inspect or list tags."

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"
  load_repo_config $name
  is_owner_or_root $name           || die "Permission denied: Repository $name is owned by $CVMFS_USER"
  is_stratum0 $name                || die "This is not a stratum 0 repository"
  ! is_publishing $name            || die "Repository is currently publishing"
  health_check -r $name

  local base_hash="$(get_mounted_root_hash $name)"
  local user_shell="$(get_user_shell $name)"
  local hash_algorithm="${CVMFS_HASH_ALGORITHM-sha1}"

  # tag listing does not need an open repository transaction
  if [ $action_list -eq 1 ] || [ $actions -eq 0 ]; then
    local tag_list_command="$(__swissknife_cmd dbg) tag_list \
      -w $CVMFS_STRATUM0                                     \
      -t ${CVMFS_SPOOL_DIR}/tmp                              \
      -p /etc/cvmfs/keys/${name}.pub                         \
      -z /etc/cvmfs/repositories.d/${name}/trusted_certs     \
      -f $name                                               \
      -b $base_hash"
    if [ $machine_readable -ne 0 ]; then
      tag_list_command="$tag_list_command -x"
    fi
    $user_shell "$tag_list_command"
    return $?
  fi

  # tag inspection does not need to open a repository transaction
  if [ $action_inspect -eq 1 ]; then
    local tag_inspect_command="$(__swissknife_cmd dbg) tag_info \
      -w $CVMFS_STRATUM0                                        \
      -t ${CVMFS_SPOOL_DIR}/tmp                                 \
      -p /etc/cvmfs/keys/${name}.pub                            \
      -z /etc/cvmfs/repositories.d/${name}/trusted_certs        \
      -f $name                                                  \
      -n $tag_name"
    if [ $machine_readable -ne 0 ]; then
      tag_inspect_command="$tag_inspect_command -x"
    fi
    $user_shell "$tag_inspect_command"
    return $?
  fi

  # all following commands need an open repository transaction and are supposed
  # to commit or abort it after performing a tag database manipulation. Hence,
  # they also need to performed by the repository owner or root
  [ ! -z "$tag_name" -o ! -z "$tag_names" ] || die "Tag name missing"
  echo "$tag_name" | grep -q -v " "         || die "Spaces are not allowed in tag names"

  is_in_transaction $name && die "Cannot change repository tags while in a transaction"
  trap "close_transaction $name 0" EXIT HUP INT TERM
  open_transaction $name || die "Failed to open transaction for tag manipulation"

  # adds (or moves) a tag in the database
  if [ $action_add -eq 1 ]; then
    local new_manifest="${CVMFS_SPOOL_DIR}/tmp/manifest"
    local tag_create_command="$(__swissknife_cmd dbg) tag_create \
      -w $CVMFS_STRATUM0                                         \
      -t ${CVMFS_SPOOL_DIR}/tmp                                  \
      -p /etc/cvmfs/keys/${name}.pub                             \
      -z /etc/cvmfs/repositories.d/${name}/trusted_certs         \
      -f $name                                                   \
      -r $CVMFS_UPSTREAM_STORAGE                                 \
      -m $new_manifest                                           \
      -b $base_hash                                              \
      -e $hash_algorithm                                         \
      $(get_follow_http_redirects_flag)                          \
      -a $tag_name"
    if [ ! -z "$add_tag_channel" ]; then
      tag_create_command="$tag_create_command -c $add_tag_channel"
    fi
    if [ ! -z "$add_tag_description" ]; then
      tag_create_command="$tag_create_command -d \"$add_tag_description\""
    fi
    if [ ! -z "$add_tag_root_hash" ]; then
      tag_create_command="$tag_create_command -h $add_tag_root_hash"
    fi
    $user_shell "$tag_create_command" || exit 1
    sign_manifest $name $new_manifest || die "Failed to sign repo"
  fi

  # removes one or more tags from the database
  if [ $action_remove -eq 1 ]; then
    if [ $remove_tag_force -eq 0 ]; then
      echo "You are about to remove these tags from $name:"
      for t in $tag_names; do echo "* $t"; done
      echo
      local reply
      read -p "Are you sure (y/N)? " reply
      if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
        return 1
      fi
    fi

    local new_manifest="${CVMFS_SPOOL_DIR}/tmp/manifest"
    $user_shell "$(__swissknife_cmd dbg) tag_remove      \
      -w $CVMFS_STRATUM0                                 \
      -t ${CVMFS_SPOOL_DIR}/tmp                          \
      -p /etc/cvmfs/keys/${name}.pub                     \
      -z /etc/cvmfs/repositories.d/${name}/trusted_certs \
      -f $name                                           \
      -r $CVMFS_UPSTREAM_STORAGE                         \
      -m $new_manifest                                   \
      -b $base_hash                                      \
      -e $hash_algorithm                                 \
      -d '$tag_names'" || die "Did not remove anything"
    sign_manifest $name $new_manifest || die "Failed to sign repo"
  fi
}


################################################################################


cvmfs_server_lstags() {
  cvmfs_server_tag -l "$@" # backward compatibility alias
  echo "NOTE: cvmfs_server lstags is deprecated! Use cvmfs_server tag instead" 1>&2
}

cvmfs_server_list_tags() {
  cvmfs_server_tag -l "$@" # backward compatibility alias
  echo "NOTE: cvmfs_server list-tags is deprecated! Use cvmfs_server tag instead" 1>&2
}


################################################################################


cvmfs_server_check() {
  local name
  local upstream
  local storage_dir
  local url
  local check_chunks=1
  local check_integrity=0
  local subtree_path=""
  local tag=

  # optional parameter handling
  OPTIND=1
  while getopts "cit:s:" option
  do
    case $option in
      c)
        check_chunks=0
      ;;
      i)
        check_integrity=1
      ;;
      t)
        tag="-n $OPTARG"
      ;;
      s)
        subtree_path="$OPTARG"
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command check: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"

  # get repository information
  load_repo_config $name

  # more sanity checks
  is_owner_or_root $name || die "Permission denied: Repository $name is owned by $CVMFS_USER"
  health_check -r $name

  # check if repository is compatible to the installed CernVM-FS version
  check_repository_compatibility $name

  upstream=$CVMFS_UPSTREAM_STORAGE
  if is_stratum1 $name; then
    url=$CVMFS_STRATUM1
  else
    url=$CVMFS_STRATUM0
  fi

  # do it!
  if [ $check_integrity -ne 0 ]; then
    if ! is_local_upstream $upstream; then
      echo "Storage Integrity Check only works locally. skipping."
    else
      echo
      echo "Checking Storage Integrity of $name ... (may take a while)"
      storage_dir=$(get_upstream_config $upstream)
      __swissknife scrub -r ${storage_dir}/data || die "FAIL!"
    fi
  fi

  [ "x$CVMFS_LOG_LEVEL" != x ] && log_level_param="-l $CVMFS_LOG_LEVEL"
  [ $check_chunks -ne 0 ]      && check_chunks_param="-c"

  local subtree_msg=""
  local subtree_param=""
  if [ "x$subtree_path" != "x" ]; then
    subtree_param="-s '$subtree_path'"
    subtree_msg=" (starting at nested catalog '$subtree_path')"
  fi

  local with_reflog=
  has_reflog_checksum $name && with_reflog="-R $(get_reflog_checksum $name)"

  echo "Verifying Catalog Integrity of ${name}${subtree_msg}..."
  local user_shell="$(get_user_shell $name)"
  local check_cmd
  check_cmd="$(__swissknife_cmd dbg) check $tag        \
                     $check_chunks_param               \
                     $log_level_param                  \
                     $subtree_param                    \
                     -r $url                           \
                     -t ${CVMFS_SPOOL_DIR}/tmp         \
                     -k ${CVMFS_PUBLIC_KEY}            \
                     -N ${CVMFS_REPOSITORY_NAME}       \
                     $(get_follow_http_redirects_flag) \
                     $with_reflog                      \
                     -z /etc/cvmfs/repositories.d/${name}/trusted_certs"
  $user_shell "$check_cmd"
}


################################################################################


cvmfs_server_list() {
  for repository in /etc/cvmfs/repositories.d/*; do
    if [ "x$repository" = "x/etc/cvmfs/repositories.d/*" ]; then
      return 0
    fi
    if [ -f $repository ]; then
      echo "Warning: unexpected file '$repository' in directory /etc/cvmfs/repositories.d/"
      continue
    fi
    local name=$(basename $repository)
    load_repo_config $name

    # figure out the schema version of the repository
    local version_info=""
    local creator_version=$(repository_creator_version $name)
    if ! version_equal $creator_version; then
      local compatible=""
      if ! check_repository_compatibility $name "nokill"; then
        compatible=" INCOMPATIBLE"
      fi
      version_info="(created by$compatible CernVM-FS $(mangle_version_string $creator_version))"
    else
      version_info=""
    fi

    # collect additional information about aliased stratum1 repos
    local stratum1_info=""
    if is_stratum1 $name; then
      if [ "$CVMFS_REPOSITORY_NAME" != "$name" ]; then
        stratum1_info="-> $CVMFS_REPOSITORY_NAME"
      fi
    fi

    # find out if the repository is currently in a transaction
    local transaction_info=""
    if is_stratum0 $name && is_in_transaction $name; then
      transaction_info=" - in transaction"
    fi

    # check if the repository whitelist is accessible and expired
    local whitelist_info=""
    if is_stratum0 $name; then
      local retval=0
      check_expiry $name $CVMFS_STRATUM0 2>/dev/null || retval=$?
      if [ $retval -eq 100 ]; then
        whitelist_info=" - whitelist unreachable"
      elif [ $retval -ne 0 ]; then
        whitelist_info=" - whitelist expired"
      fi
    fi

    # check if the repository is healthy
    local health_info=""
    if ! health_check -q $name; then
      health_info=" - unhealthy"
    fi

    # get the storage type of the repository
    local storage_type=""
    storage_type=$(get_upstream_type $CVMFS_UPSTREAM_STORAGE)

    # print out repository information list
    echo "$name ($CVMFS_REPOSITORY_TYPE / $storage_type$transaction_info$whitelist_info$health_info) $stratum1_info $version_info"
    CVMFS_CREATOR_VERSION=""
  done
}


################################################################################


################################################################################


cvmfs_server_rollback() {
  local name
  local user
  local spool_dir
  local stratum0
  local upstream
  local target_tag=""
  local undo_rollback=1
  local force=0

  # optional parameter handling
  OPTIND=1
  while getopts "t:f" option
  do
    case $option in
      t)
        target_tag=$OPTARG
        undo_rollback=0
      ;;
      f)
        force=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command rollback: Unrecognized option: $1"
      ;;
    esac
  done

  # get repository name
  shift $(($OPTIND-1))
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $1)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"
  is_stratum0 $name                || die "This is not a stratum 0 repository"
  is_publishing $name              && die "Repository $name is currently being published"
  health_check -r $name

  # get repository information
  load_repo_config $name
  user=$CVMFS_USER
  spool_dir=$CVMFS_SPOOL_DIR
  stratum0=$CVMFS_STRATUM0
  upstream=$CVMFS_UPSTREAM_STORAGE

  # more sanity checks
  is_owner_or_root $name || die "Permission denied: Repository $name is owned by $user"
  check_repository_compatibility $name
  check_expiry $name $stratum0  || die "Repository whitelist is expired!"
  is_in_transaction $name && die "Cannot rollback a repository in a transaction"
  is_cwd_on_path "/cvmfs/$name" && die "Current working directory is in /cvmfs/$name.  Please release, e.g. by 'cd \$HOME'." || true

  if [ $undo_rollback -eq 1 ]; then
    if ! check_tag_existence $name "trunk-previous"; then
      die "More than one anonymous undo rollback is not supported. Please specify a tag name (-t)"
    fi
  elif ! check_tag_existence $name "$target_tag"; then
    die "Target tag '$target_tag' does not exist"
  fi

  if [ $force -ne 1 ]; then
    local reply
    if [ $undo_rollback -eq 1 ]; then
      read -p "You are about to UNDO your last published revision!  Are you sure (y/N)? " reply
    else
      read -p "You are about to ROLLBACK to $target_tag AS THE LATEST REVISION!  Are you sure (y/N)? " reply
    fi
    if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
      return 1
    fi
  fi

  # prepare the shell commands
  local user_shell="$(get_user_shell $name)"
  local base_hash=$(get_mounted_root_hash $name)
  local hash_algorithm="${CVMFS_HASH_ALGORITHM-sha1}"

  local rollback_command="$(__swissknife_cmd dbg) tag_rollback \
    -w $stratum0                                               \
    -t ${spool_dir}/tmp                                        \
    -p /etc/cvmfs/keys/${name}.pub                             \
    -z /etc/cvmfs/repositories.d/${name}/trusted_certs         \
    -f $name                                                   \
    -r $upstream                                               \
    -m ${spool_dir}/tmp/manifest                               \
    -b $base_hash                                              \
    -e $hash_algorithm"
  if [ ! -z "$target_tag" ]; then
    rollback_command="$rollback_command -n $target_tag"
  fi

  # do it!
  echo "Rolling back repository (leaving behind $base_hash)"
  trap "close_transaction $name 0" EXIT HUP INT TERM
  open_transaction $name || die "Failed to open transaction for rollback"

  $user_shell "$rollback_command" || die "Rollback failed\n\nExecuted Command:\n$rollback_command";

  local trunk_hash=$(grep "^C" ${spool_dir}/tmp/manifest | tr -d C)
  sign_manifest $name ${spool_dir}/tmp/manifest || die "Signing failed";
  set_ro_root_hash $name $trunk_hash

  echo "Flushing file system buffers"
  sync
}


################################################################################


cvmfs_server_gc() {
  local names
  local list_deleted_objects=0
  local dry_run=0
  local preserve_revisions=-1
  local preserve_timestamp=0
  local timestamp_threshold=""
  local force=0
  local deletion_log=""
  local reconstruct_reflog="0"

  # optional parameter handling
  OPTIND=1
  while getopts "ldr:t:fL:" option
  do
    case $option in
      l)
        list_deleted_objects=1
      ;;
      d)
        dry_run=1
      ;;
      r)
        preserve_revisions="$OPTARG"
      ;;
      t)
        timestamp_threshold="$OPTARG"
      ;;
      f)
        force=1
      ;;
      L)
        deletion_log="$OPTARG"
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command gc: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  # get repository names
  check_parameter_count_for_multiple_repositories $#
  names=$(get_or_guess_multiple_repository_names $@)
  check_multiple_repository_existence "$names"

  # parse timestamp (if given)
  if [ ! -z "$timestamp_threshold"  ]; then
    preserve_timestamp="$(date --date "$timestamp_threshold" +%s 2>/dev/null)" || die "Cannot parse time stamp '$timestamp_threshold'"
  fi

  [ $preserve_revisions -ge 0 ] && [ $preserve_timestamp -gt 0 ] && die "Please specify either timestamp OR revision thresholds (-r and -t are mutual exclusive)"
  if [ $preserve_revisions -lt 0 ] && [ $preserve_timestamp -le 0 ]; then
    # neither revision nor timestamp threshold given... fallback to default
    preserve_timestamp="$(date --date '3 days ago' +%s 2>/dev/null)"
  fi

  for name in $names; do
    if ! has_reference_log $name; then
      reconstruct_reflog=1
    fi
  done

  # sanity checks
  if [ $dry_run -ne 0 ] && [ $reconstruct_reflog -ne 0 ]; then
    die "Reflog reconstruction needed. Cannot do a dry-run."
  fi

  # safety user confirmation
  if [ $force -eq 0 ] && [ $dry_run -eq 0 ]; then
    echo "YOU ARE ABOUT TO DELETE DATA! Are you sure you want to do the following:"
  fi

  local dry_run_msg="no"
  if [ $dry_run -eq 1 ]; then dry_run_msg="yes"; fi

  local reflog_reconstruct_msg="no"
  if [ $reconstruct_reflog -eq 1 ]; then reflog_reconstruct_msg="yes"; fi

  echo "Affected Repositories:         $names"
  echo "Dry Run (no actual deletion):  $dry_run_msg"
  echo "Needs Reflog reconstruction:   $reflog_reconstruct_msg"
  if [ $preserve_revisions -ge 0 ]; then
    echo "Preserved Legacy Revisions:    $preserve_revisions"
  fi
  if [ $preserve_timestamp -gt 0 ]; then
    echo "Preserve Revisions newer than: $(date -d@$preserve_timestamp +'%x %X')"
  fi
  if [ $preserve_revisions -le 0 ] && [ $preserve_timestamp -le 0 ]; then
    echo "Only the latest revision will be preserved."
  fi

  if [ $force -eq 0 ]; then
    echo ""
    read -p "Please confirm this action (y/N)? " reply
    if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
      return 1
    fi
  fi

  for name in $names; do

    load_repo_config $name

    # sanity checks
    check_repository_compatibility $name
    if is_empty_repository $name; then
      echo "Repository $name is empty, nothing to do"
      continue
    fi
    is_garbage_collectable $name || die "Garbage Collection is not enabled for $name"
    is_owner_or_root       $name || die "Permission denied: Repository $name is owned by $user"
    is_in_transaction      $name && die "Cannot run garbage collection while in a transaction"

    local head_timestamp="$(get_repo_info -t)"
    [ $head_timestamp -gt $preserve_timestamp ] || die "Latest repository revision is older than given timestamp"

    # figure out the URL of the repository
    local repository_url="$CVMFS_STRATUM0"
    if is_stratum1 $name; then
      [ ! -z $CVMFS_STRATUM1 ] || die "Missing CVMFS_STRATUM1 URL in server.conf"
      repository_url="$CVMFS_STRATUM1"
    fi

    # generate the garbage collection configuration
    local additional_switches=""
    [ $list_deleted_objects -ne 0 ] && additional_switches="$additional_switches -l"
    [ $dry_run              -ne 0 ] && additional_switches="$additional_switches -d"
    [ $preserve_revisions   -ge 0 ] && additional_switches="$additional_switches -h $preserve_revisions"
    [ $preserve_timestamp   -gt 0 ] && additional_switches="$additional_switches -z $preserve_timestamp"

    # retrieve the base hash of the repository to be editied
    local base_hash=""
    local manifest=""

    # gather extra information for a stratum0 repository and open a transaction
    if is_stratum0 $name; then
      base_hash="$(get_mounted_root_hash $name)"
      manifest="${CVMFS_SPOOL_DIR}/tmp/manifest"

      if [ $dry_run -eq 0 ]; then
        trap "close_transaction $name 0" EXIT HUP INT TERM
        open_transaction $name || die "Failed to open transaction for garbage collection"
      fi
    fi

    to_syslog_for_repo $name "started manual garbage collection"

    local reconstruct_this_reflog=0
    if ! has_reference_log $name; then
      reconstruct_this_reflog=1
    fi

    # run the garbage collection
    local reflog_reconstruct_msg=""
    [ $reconstruct_this_reflog -ne 0 ] && reflog_reconstruct_msg="(reconstructing reference logs)"
    echo "Running Garbage Collection $reflog_reconstruct_msg"
    __run_gc "$name"                    \
             "$repository_url"          \
             "$dry_run"                 \
             "$manifest"                \
             "$base_hash"               \
             "$deletion_log"            \
             "$reconstruct_this_reflog" \
             $additional_switches || die "Fail ($?)!"

    # sign the result
    if is_stratum0 $name && [ $dry_run -eq 0 ]; then
      echo "Signing Repository Manifest"
      if ! sign_manifest $name $manifest; then
        to_syslog_for_repo $name "failed to sign manifest after manual garbage collection"
        die "Fail!"
      fi

      # close the transaction
      trap - EXIT HUP INT TERM
      close_transaction $name 0
    fi

    to_syslog_for_repo $name "successfully finished manual garbage collection"

  done
}

__run_gc() {
  local name="$1"
  local repository_url="$2"
  local dry_run="$3"
  local manifest="$4"
  local base_hash="$5"
  local deletion_log="$6"
  local reconstruct_reflog="$7"
  shift 7
  local additional_switches="$*"

  load_repo_config $name

  # sanity checks
  is_garbage_collectable $name  || return 1
  [ x"$repository_url" != x"" ] || return 2
  if [ $dry_run -eq 0 ]; then
    is_in_transaction $name || is_stratum1 $name || return 3
  else
    [ $reconstruct_reflog -eq 0 ] || return 8
  fi

  if is_stratum0 $name; then
    [ x"$manifest"  != x"" ] || return 4
    [ x"$base_hash" != x"" ] || return 5
  fi

  if ! has_reference_log $name && [ $reconstruct_reflog -eq 0 ]; then
    return 9
  fi

  # handle a configured deletion log (manually passed log has precedence)
  if [ x"$deletion_log" != x"" ]; then
    additional_switches="$additional_switches -L $deletion_log"
  elif [ ! -z $CVMFS_GC_DELETION_LOG ]; then
    additional_switches="$additional_switches -L $CVMFS_GC_DELETION_LOG"
  fi

  # do it!
  local user_shell="$(get_user_shell $name)"

  if [ $reconstruct_reflog -ne 0 ]; then
    to_syslog_for_repo $name "reference log reconstruction started"
    local reflog_reconstruct_command="$(__swissknife_cmd dbg) reconstruct_reflog \
                                                  -r $repository_url             \
                                                  -u $CVMFS_UPSTREAM_STORAGE     \
                                                  -n $CVMFS_REPOSITORY_NAME      \
                                                  -t ${CVMFS_SPOOL_DIR}/tmp/     \
                                                  -k $CVMFS_PUBLIC_KEY           \
                                                  -R $(get_reflog_checksum $name)"
    if ! $user_shell "$reflog_reconstruct_command"; then
      to_syslog_for_repo $name "failed to reconstruction reference log"
    else
      to_syslog_for_repo $name "successfully reconstructed reference log"
    fi
  fi

  [ $dry_run -ne 0 ] || to_syslog_for_repo $name "started garbage collection"
  local gc_command="$(__swissknife_cmd dbg) gc                              \
                                            -r $repository_url              \
                                            -u $CVMFS_UPSTREAM_STORAGE      \
                                            -n $CVMFS_REPOSITORY_NAME       \
                                            -k $CVMFS_PUBLIC_KEY            \
                                            -t ${CVMFS_SPOOL_DIR}/tmp/      \
                                            -R $(get_reflog_checksum $name) \
                                            $additional_switches"

  if ! $user_shell "$gc_command"; then
    [ $dry_run -ne 0 ] || to_syslog_for_repo $name "failed to garbage collect"
    return 6
  fi

  local hash_algorithm="${CVMFS_HASH_ALGORITHM-sha1}"
  if is_stratum0 $name && [ $dry_run -eq 0 ]; then
    tag_command="$(__swissknife_cmd dbg) tag_empty_bin \
      -r $CVMFS_UPSTREAM_STORAGE                       \
      -w $CVMFS_STRATUM0                               \
      -t ${CVMFS_SPOOL_DIR}/tmp                        \
      -m $manifest                                     \
      -p /etc/cvmfs/keys/${name}.pub                   \
      -f $name                                         \
      -b $base_hash                                    \
      -e $hash_algorithm"
    if ! $user_shell "$tag_command"; then
      to_syslog_for_repo $name "failed to update history after garbage collection"
      return 7
    fi
  fi

  [ $dry_run -ne 0 ] || to_syslog_for_repo $name "successfully finished garbage collection"

  return 0
}


################################################################################


__snapshot_cleanup() {
  local alias_name=$1

  load_repo_config $alias_name
  local user_shell="$(get_user_shell $alias_name)"
  $user_shell "$(__swissknife_cmd) remove     \
                 -r ${CVMFS_UPSTREAM_STORAGE} \
                 -o .cvmfs_is_snapshotting"       || echo "Warning: failed to remove .cvmfs_is_snapshotting"
  release_lock ${CVMFS_SPOOL_DIR}/is_snapshotting || echo "Warning: failed to release snapshotting lock"
}

__snapshot_succeeded() {
  local alias_name=$1
  __snapshot_cleanup $alias_name
  to_syslog_for_repo $alias_name "successfully snapshotted from $CVMFS_STRATUM0"
}

__snapshot_failed() {
  local alias_name=$1
  __snapshot_cleanup $alias_name
  to_syslog_for_repo $alias_name "failed to snapshot from $CVMFS_STRATUM0"
}

__do_snapshot() {
  local alias_names="$1"
  local abort_on_conflict=$2
  local alias_name
  local name
  local user
  local spool_dir
  local stratum0
  local upstream
  local num_workers
  local public_key
  local timeout
  local retries
  local retcode=0
  local gc_timespan=0

  for alias_name in $alias_names; do

    # sanity checks
    is_stratum1 $alias_name || { echo "Repository $alias_name is not a stratum 1 repository"; retcode=1; continue; }

    # get repository information
    load_repo_config $alias_name
    name=$CVMFS_REPOSITORY_NAME
    user=$CVMFS_USER
    spool_dir=$CVMFS_SPOOL_DIR
    stratum0=$CVMFS_STRATUM0
    stratum1=$CVMFS_STRATUM1
    upstream=$CVMFS_UPSTREAM_STORAGE
    num_workers=$CVMFS_NUM_WORKERS
    public_key=$CVMFS_PUBLIC_KEY
    timeout=$CVMFS_HTTP_TIMEOUT
    retries=$CVMFS_HTTP_RETRIES
    snapshot_lock=${spool_dir}/is_snapshotting

    # more sanity checks
    is_owner_or_root $alias_name || { echo "Permission denied: Repository $alias_name is owned by $user"; retcode=1; continue; }
    check_repository_compatibility $alias_name
    [ ! -z $stratum1 ] || die "Missing CVMFS_STRATUM1 URL in server.conf"
    gc_timespan="$(get_auto_garbage_collection_timespan $alias_name)" || { retcode=1; continue; }
    if is_local_upstream $upstream && is_root && check_apache; then
      # this might have been missed if add-replica -a was used or
      #  if a migrate was done while apache wasn't running, but then
      #  apache was enabled later
      # unfortunately we can only check it if snapshot is run as root...
      check_wsgi_module
    fi

    # do it!
    local user_shell="$(get_user_shell $alias_name)"

    if is_local_upstream $upstream; then
        # try to update the geodb, but continue if it doesn't work
        _update_geodb -l || true
    fi

    local initial_snapshot=0
    local initial_snapshot_flag=""
    if $user_shell "$(__swissknife_cmd) peek -d .cvmfs_last_snapshot -r ${upstream}" | grep -v -q "available"; then
      initial_snapshot=1
      initial_snapshot_flag="-i"
    fi

    # check for other snapshots in progress
    if ! acquire_lock $snapshot_lock; then
      if [ $abort_on_conflict -eq 1 ]; then
        echo "another snapshot is in progress... aborting"
        to_syslog_for_repo $alias_name "did not snapshot (another snapshot in progress)"
        retcode=1
        continue
      fi

      if [ $initial_snapshot -eq 1 ]; then
        echo "an initial snapshot is in progress... aborting"
        to_syslog_for_repo $alias_name "did not snapshot (another initial snapshot in progress)"
        retcode=1
        continue
      fi

      echo "waiting for another snapshot to finish..."
      if ! wait_and_acquire_lock $snapshot_lock; then
        echo "failed to acquire snapshot lock"
        to_syslog_for_repo $alias_name "did not snapshot (locking issues)"
        retcode=1
        continue
      fi
    fi

    # here the lock is already acquired and needs to be cleared in case of abort
    trap "__snapshot_failed $alias_name" EXIT HUP INT TERM
    to_syslog_for_repo $alias_name "started snapshotting from $stratum0"

    local log_level=
    [ "x$CVMFS_LOG_LEVEL" != x ] && log_level="-l $CVMFS_LOG_LEVEL"
    if [ $initial_snapshot -eq 1 ]; then
      echo "Initial snapshot"
    fi

    # put a magic file in the repository root to signal a snapshot in progress
    local snapshotting_tmp="${spool_dir}/tmp/snapshotting"
    $user_shell "date > $snapshotting_tmp"
    $user_shell "$(__swissknife_cmd) upload -r ${upstream} \
      -i $snapshotting_tmp                                 \
      -o .cvmfs_is_snapshotting"
    $user_shell "rm -f $snapshotting_tmp"

    # do the actual snapshot actions
    local with_history=""
    local with_reflog=""
    local timestamp_threshold=""
    [ $initial_snapshot -ne 1 ] && with_history="-p"
    [ $initial_snapshot -eq 1 ] && \
      with_reflog="-R $(get_reflog_checksum $alias_name)"
    has_reflog_checksum $alias_name && \
      with_reflog="-R $(get_reflog_checksum $alias_name)"
    is_stratum0_garbage_collectable $alias_name &&
      timestamp_threshold="-Z $gc_timespan"
    $user_shell "$(__swissknife_cmd dbg) pull -m $name \
        -u $stratum0                                   \
        -w $stratum1                                   \
        -r ${upstream}                                 \
        -x ${spool_dir}/tmp                            \
        -k $public_key                                 \
        -n $num_workers                                \
        -t $timeout                                    \
        -a $retries $with_history $with_reflog         \
           $initial_snapshot_flag $timestamp_threshold $log_level"

    local last_snapshot_tmp="${spool_dir}/tmp/last_snapshot"
    $user_shell "date --utc > $last_snapshot_tmp"
    $user_shell "$(__swissknife_cmd) upload -r ${upstream} \
      -i $last_snapshot_tmp                                \
      -o .cvmfs_last_snapshot"
    $user_shell "rm -f $last_snapshot_tmp"

    # run the automatic garbage collection (if configured)
    if has_auto_garbage_collection_enabled $alias_name; then
      echo "Running automatic garbage collection"
      local dry_run=0
      __run_gc "$alias_name" \
               "$stratum1"   \
               "$dry_run"    \
               ""            \
               ""            \
               ""            \
               "0"           \
               -z $gc_timespan || die "Garbage collection failed ($?)"
    fi

    # all done, clear the trap and run the cleanup manually
    trap - EXIT HUP INT TERM
    __snapshot_succeeded $alias_name

  done

  return $retcode
}

__do_all_snapshots() {
  local separate_logs=0
  local logrotate_nowarn=0
  local skip_noninitial=0
  local log
  local fullog
  local repo
  local repos

  OPTIND=1
  while getopts "sni" option; do
    case $option in
      s)
        separate_logs=1
      ;;
      n)
        logrotate_nowarn=1
      ;;
      i)
        skip_noninitial=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command snapshot -a: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  if [ ! -d /var/log/cvmfs ]; then
    if ! mkdir /var/log/cvmfs 2>/dev/null; then
      die "/var/log/cvmfs does not exist and could not create it"
    fi
  fi
  [ -w /var/log/cvmfs ] || die "cannot write to /var/log/cvmfs"

  if [ $logrotate_nowarn -eq 0 ] && [ ! -f /etc/logrotate.d/cvmfs ]; then
    cat << EOF
/etc/logrotate.d/cvmfs does not exist!
To prevent this error message, create the file or use -n option.
Suggested content:
/var/log/cvmfs/*.log {
    weekly
    missingok
    notifempty
}
EOF
    exit 1
  fi

  if [ $separate_logs -eq 0 ]; then
    # write into a temporary file in case more than one is active at the
    #  same time
    fulllog=/var/log/cvmfs/snapshots.log
    log=/tmp/cvmfs_snapshots.$$.log
    trap "rm -f $log" 0
    (echo; echo "Logging in $log at `date`") >>$fulllog
  fi

  # Sort the active repositories by last snapshot time when on local storage.
  # For non-local, swissknife only supports checking whether a file exists,
  #  so only check whether non-initial snapshots are being skipped.
  repos="$(for replica in /etc/cvmfs/repositories.d/*/replica.conf; do

    # get repository information
    local repodir="${replica%/*}"
    repo="${repodir##*/}"
    unset CVMFS_REPLICA_ACTIVE # remove previous setting, default is yes
    load_repo_config $repo

    if [ "$CVMFS_REPLICA_ACTIVE" = "no" ]; then
      continue
    fi

    local upstream=$CVMFS_UPSTREAM_STORAGE
    local snapshot_time=0
    if is_local_upstream $upstream; then
      local storage_dir=$(get_upstream_config $upstream)
      local snapshot_file=$storage_dir/.cvmfs_last_snapshot
      if [ -f $snapshot_file ]; then
        snapshot_time="$(stat --format='%Y' $snapshot_file)"
      elif [ $skip_noninitial -eq 1 ]; then
        continue
      fi
    elif [ $skip_noninitial -eq 1 ]; then
      if $user_shell "$(__swissknife_cmd) peek -d .cvmfs_last_snapshot -r ${upstream}" | grep -v -q "available"; then
        continue
      fi
    fi

    echo "${snapshot_time}:${repo}"

  done|sort -n|cut -d: -f2)"

  for repo in $repos; do
    if [ $separate_logs -eq 1 ]; then
      log=/var/log/cvmfs/$repo.log
    fi

    (
    echo
    echo "Starting $repo at `date`"
    # Work around the errexit (that is, set -e) misfeature of being
    #  disabled whenever the exit code is to be checked.
    # See https://lists.gnu.org/archive/html/bug-bash/2012-12/msg00093.html
    set +e
    (set -e
    __do_snapshot $repo 1
    )
    if [ $? != 0 ]; then
      echo "ERROR from cvmfs_server snapshot!" >&2
    fi
    echo "Finished $repo at `date`"
    ) >> $log 2>&1

    if [ $separate_logs -eq 0 ]; then
      cat $log >>$fulllog
      > $log
    fi

  done
}

cvmfs_server_snapshot() {
  local alias_names
  local retcode=0
  local abort_on_conflict=0
  local do_all=0
  local allopts=""

  OPTIND=1
  while getopts "atsni" option; do
    case $option in
      a)
        do_all=1
      ;;
      s|n|i)
        allopts="$allopts -$option"
      ;;
      t)
        abort_on_conflict=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command snapshot: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  if [ $do_all -eq 1 ]; then
    [ $# -eq 0 ] || die "no non-option parameters expected with -a"

    # ignore if there's a -t option, it's always implied with -a

    __do_all_snapshots $allopts

    # always return success because this is used from cron and we
    #  don't want cron sending an email every time something fails
    # errors will be in the log

  else
    if [ -n "$allopts" ]; then
      usage "Command snapshot:$allopts unrecognized without -a"
    fi

    # get repository names
    check_parameter_count_for_multiple_repositories $#
    alias_names=$(get_or_guess_multiple_repository_names $@)
    check_multiple_repository_existence "$alias_names"

    __do_snapshot "$alias_names" $abort_on_conflict
    retcode=$?
  fi

  return $retcode
}

################################################################################


_migrate_2_1_6() {
  local name=$1
  local destination_version="2.1.7"

  # get repository information
  load_repo_config $name

  echo "Migrating repository '$name' from CernVM-FS $(mangle_version_string '2.1.6') to $(mangle_version_string '2.1.7')"

  echo "--> generating new upstream descriptor"
  # before 2.1.6 there were only local backends... no need to differentiate here
  local storage_path=$(echo $CVMFS_UPSTREAM_STORAGE | cut --delimiter=: --fields=2)
  local new_upstream="local,${storage_path}/data/txn,${storage_path}"

  echo "--> removing spooler pipes"
  local pipe_pathes="${CVMFS_SPOOL_DIR}/paths"
  local pipe_digests="${CVMFS_SPOOL_DIR}/digests"
  rm -f $pipe_pathes > /dev/null 2>&1 || echo "Warning: not able to delete $pipe_pathes"
  rm -f $pipe_digests > /dev/null 2>&1 || echo "Warning: not able to delete $pipe_digests"

  if is_stratum0 $name; then
    echo "--> create temp directory in upstream storage"
    local tmp_dir=${storage_path}/data/txn
    mkdir $tmp_dir > /dev/null 2>&1 || echo "Warning: not able to create $tmp_dir"
    chown -R $CVMFS_USER $tmp_dir > /dev/null 2>&1 || echo "Warning: not able to chown $tmp_dir to $CVMFS_USER"
    set_selinux_httpd_context_if_needed $tmp_dir || echo "Warning: not able to chcon $tmp_dir to httpd_sys_content_t"

    echo "--> updating server.conf"
    mv /etc/cvmfs/repositories.d/${name}/server.conf /etc/cvmfs/repositories.d/${name}/server.conf.old
    cat > /etc/cvmfs/repositories.d/${name}/server.conf << EOF
# created by cvmfs_server.
# migrated from version $(mangle_version_string "2.1.6").
CVMFS_CREATOR_VERSION=$destination_version
CVMFS_REPOSITORY_NAME=$CVMFS_REPOSITORY_NAME
CVMFS_REPOSITORY_TYPE=$CVMFS_REPOSITORY_TYPE
CVMFS_USER=$CVMFS_USER
CVMFS_UNION_DIR=$CVMFS_UNION_DIR
CVMFS_SPOOL_DIR=$CVMFS_SPOOL_DIR
CVMFS_STRATUM0=$CVMFS_STRATUM0
CVMFS_UPSTREAM_STORAGE=$new_upstream
CVMFS_USE_FILE_CHUNKING=$CVMFS_DEFAULT_USE_FILE_CHUNKING
CVMFS_MIN_CHUNK_SIZE=$CVMFS_DEFAULT_MIN_CHUNK_SIZE
CVMFS_AVG_CHUNK_SIZE=$CVMFS_DEFAULT_AVG_CHUNK_SIZE
CVMFS_MAX_CHUNK_SIZE=$CVMFS_DEFAULT_MAX_CHUNK_SIZE
EOF
  fi

  if is_stratum1 $name; then
    echo "--> updating server.conf"
    mv /etc/cvmfs/repositories.d/${name}/server.conf /etc/cvmfs/repositories.d/${name}/server.conf.old
    cat > /etc/cvmfs/repositories.d/${name}/server.conf << EOF
# Created by cvmfs_server.
# migrated from version $(mangle_version_string "2.1.6").
CVMFS_CREATOR_VERSION=$destination_version
CVMFS_REPOSITORY_NAME=$CVMFS_REPOSITORY_NAME
CVMFS_REPOSITORY_TYPE=$CVMFS_REPOSITORY_TYPE
CVMFS_USER=$CVMFS_USER
CVMFS_SPOOL_DIR=$CVMFS_SPOOL_DIR
CVMFS_STRATUM0=$CVMFS_STRATUM0
CVMFS_UPSTREAM_STORAGE=$new_upstream
EOF
  fi

  # reload repository information
  load_repo_config $name
}


_migrate_2_1_7() {
  local name=$1
  local destination_version="2.1.15"

  # get repository information
  load_repo_config $name
  local user_shell="$(get_user_shell $name)"

  echo "Migrating repository '$name' from CernVM-FS $CVMFS_CREATOR_VERSION to $(mangle_version_string $destination_version)"

  if [ ! -f ${CVMFS_SPOOL_DIR}/client.local ]; then
    echo "--> creating client.local"
    $user_shell "touch ${CVMFS_SPOOL_DIR}/client.local" || die "fail!"
  fi

  local server_conf="/etc/cvmfs/repositories.d/${name}/server.conf"
  if ! cat $server_conf | grep -q CVMFS_UNION_FS_TYPE; then
    echo "--> setting AUFS as used overlay file system"
    echo "CVMFS_UNION_FS_TYPE=aufs" >> $server_conf
  fi

  if ! grep client.local /etc/fstab | grep -q ${CVMFS_REPOSITORY_NAME}; then
    echo "--> adjusting /etc/fstab"
    sed -i -e "s|cvmfs2#${CVMFS_REPOSITORY_NAME} ${CVMFS_SPOOL_DIR}/rdonly fuse allow_other,config=/etc/cvmfs/repositories.d/${CVMFS_REPOSITORY_NAME}/client.conf,cvmfs_suid 0 0 # added by CernVM-FS for ${CVMFS_REPOSITORY_NAME}|cvmfs2#${CVMFS_REPOSITORY_NAME} ${CVMFS_SPOOL_DIR}/rdonly fuse allow_other,config=/etc/cvmfs/repositories.d/${CVMFS_REPOSITORY_NAME}/client.conf:${CVMFS_SPOOL_DIR}/client.local,cvmfs_suid 0 0 # added by CernVM-FS for ${CVMFS_REPOSITORY_NAME}|" /etc/fstab
    if ! grep client.local /etc/fstab | grep -q ${CVMFS_REPOSITORY_NAME}; then
      die "fail!"
    fi
  fi

  echo "--> analyzing file catalogs for additional statistics counters"
  local temp_dir="${CVMFS_SPOOL_DIR}/tmp"
  local new_manifest="${temp_dir}/new_manifest"

  __swissknife migrate                                 \
    -v "2.1.7"                                         \
    -r ${CVMFS_STRATUM0}                               \
    -n $name                                           \
    -u ${CVMFS_UPSTREAM_STORAGE}                       \
    -t $temp_dir                                       \
    -o $new_manifest                                   \
    -k /etc/cvmfs/keys/$name.pub                       \
    -z /etc/cvmfs/repositories.d/${name}/trusted_certs \
    -s || die "fail! (migrating catalogs)"
  chown ${CVMFS_USER} $new_manifest

  # sign new (migrated) repository revision
  echo -n "Signing newly imported Repository... "
  create_whitelist $name ${CVMFS_USER} ${CVMFS_UPSTREAM_STORAGE} $temp_dir > /dev/null
  sign_manifest $name $new_manifest || die "fail! (cannot sign repo)"
  echo "done"

  echo "--> updating server.conf"
  sed -i -e "s/^CVMFS_CREATOR_VERSION=.*/CVMFS_CREATOR_VERSION=$destination_version/" /etc/cvmfs/repositories.d/$name/server.conf

  # reload (updated) repository information
  load_repo_config $name

  # update repository information
  echo "--> remounting (migrated) repository"
  local remote_hash
  remote_hash=$(get_published_root_hash $name)

  run_suid_helper rw_umount $name     > /dev/null 2>&1 || die "fail! (unmounting /cvmfs/$name)"
  run_suid_helper rdonly_umount $name > /dev/null 2>&1 || die "fail! (unmounting ${CVMFS_SPOOL_DIR}/rdonly)"
  set_ro_root_hash $name $remote_hash
  run_suid_helper rdonly_mount $name  > /dev/null 2>&1 || die "fail! (mounting ${CVMFS_SPOOL_DIR}/$name)"
  run_suid_helper rw_mount $name      > /dev/null 2>&1 || die "fail! (mounting /cvmfs/$name)"
}

# note that this is only run on stratum1s that have local upstream storage
_migrate_2_1_15() {
  local name=$1
  local destination_version="2.1.20"
  local conf_file
  conf_file="$(get_apache_conf_path)/$(get_apache_conf_filename $name)"

  # get repository information
  load_repo_config $name

  echo "Migrating repository '$name' from CernVM-FS $CVMFS_CREATOR_VERSION to $(mangle_version_string $destination_version)"

  if check_apache; then
    check_wsgi_module
    _update_geodb -l
  fi
  # else apache is currently stopped, add-replica may have been run with -a

  if [ -f "$conf_file" ]; then
    echo "--> updating $conf_file"
    (echo "# Created by cvmfs_server.  Don't touch."
     cat_wsgi_config $name
     sed '/^# Created by cvmfs_server/d' $conf_file) > $conf_file.NEW
    cat $conf_file.NEW >$conf_file
    rm -f $conf_file.NEW
    if check_apache; then
      # Need to restart, reload doesn't work at least for the first module;
      #  that results in repeated segmentation faults on RHEL5 & 6
      restart_apache
    fi
  else
    if check_apache; then
      echo "$conf_file does not exist."
      echo "Make sure the equivalent of the following is in the apache configuration:"
      echo ----------
    else
      echo "Apache is not enabled and $conf_file does not exist."
      echo "  If you do enable Apache, make sure the equivalent of the following is"
      echo "  in the apache configuration:"
    fi
    cat_wsgi_config $name
  fi

  echo "--> updating server.conf"
  local server_conf="/etc/cvmfs/repositories.d/${name}/server.conf"
  sed -i -e "s/^CVMFS_CREATOR_VERSION=.*/CVMFS_CREATOR_VERSION=$destination_version/" $server_conf
  echo "CVMFS_STRATUM1=$(mangle_local_cvmfs_url $name)" >> $server_conf

  # reload (updated) repository information
  load_repo_config $name
}

_migrate_2_1_20() {
  local name=$1
  local destination_version="2.2.0-1"
  local creator=$(repository_creator_version $name)
  local server_conf="/etc/cvmfs/repositories.d/${name}/server.conf"
  local apache_conf="$(get_apache_conf_path)/$(get_apache_conf_filename $name)"

  # get repository information
  load_repo_config $name

  echo "Migrating repository '$name' from CernVM-FS $(mangle_version_string $CVMFS_CREATOR_VERSION) to $(mangle_version_string $destination_version)"

  if is_stratum0 $name; then
    echo "--> updating client.conf"
    local client_conf="/etc/cvmfs/repositories.d/${name}/client.conf"
    [ -z "$CVMFS_HIDE_MAGIC_XATTRS" ] && echo "CVMFS_HIDE_MAGIC_XATTRS=yes" >> $client_conf
    [ -z "$CVMFS_FOLLOW_REDIRECTS"  ] && echo "CVMFS_FOLLOW_REDIRECTS=yes"  >> $client_conf
    [ -z "$CVMFS_SERVER_CACHE_MODE" ] && echo "CVMFS_SERVER_CACHE_MODE=yes" >> $client_conf
    [ -z "$CVMFS_MOUNT_DIR"         ] && echo "CVMFS_MOUNT_DIR=/cvmfs"      >> $client_conf

    echo "--> updating /etc/fstab"
    local tmp_fstab=$(mktemp)
    awk  "/added by CernVM-FS for $name\$/"' {
            for (i = 1; i <= NF; i++) {
              if (i == 4) $i = $i",noauto";
              printf("%s ", $i);
            }
            print "";
            next;
          };
          { print $0 }' /etc/fstab > $tmp_fstab
    cat $tmp_fstab > /etc/fstab
    rm -f $tmp_fstab

    echo "--> updating server.conf"
    if ! grep -q "CVMFS_AUTO_REPAIR_MOUNTPOINT" $server_conf; then
      echo "CVMFS_AUTO_REPAIR_MOUNTPOINT=true" >> $server_conf
    else
      sed -i -e "s/^\(CVMFS_AUTO_REPAIR_MOUNTPOINT\)=.*/\1=true/" $server_conf
    fi
  fi

  if is_local_upstream $CVMFS_UPSTREAM_STORAGE && [ -f "$apache_conf" ]; then
    echo "--> updating apache config ($(basename $apache_conf))"
    local storage_dir=$(get_upstream_config $CVMFS_UPSTREAM_STORAGE)
    local wsgi=""
    is_stratum1 $name && wsgi="enabled"
    create_apache_config_for_endpoint $name $storage_dir $wsgi
    reload_apache > /dev/null
  fi

  sed -i -e "s/^\(CVMFS_CREATOR_VERSION\)=.*/\1=$destination_version/" $server_conf

  # update repository information
  load_repo_config $name
}

_migrate_2_2() {
  local name=$1
  local destination_version="2.3.0-1"
  local server_conf="/etc/cvmfs/repositories.d/${name}/server.conf"

  # get repository information
  load_repo_config $name
  [ ! -z $CVMFS_SPOOL_DIR     ] || die "\$CVMFS_SPOOL_DIR is not set"
  [ ! -z $CVMFS_USER          ] || die "\$CVMFS_USER is not set"
  [ ! -z $CVMFS_UNION_FS_TYPE ] || die "\$CVMFS_UNION_FS_TYPE is not set"

  echo "--> umount repository"
  run_suid_helper rw_umount $name

  echo "--> updating scratch directory layout"
  local scratch_dir="${CVMFS_SPOOL_DIR}/scratch"
  rm -fR   ${scratch_dir}
  mkdir -p ${scratch_dir}/current
  mkdir -p ${scratch_dir}/wastebin
  chown -R $CVMFS_USER ${scratch_dir}

  echo "--> updating /etc/fstab"
  local comment="added by CernVM-FS for ${name}"
  sed -i -e "s~^\(.*\)\(${scratch_dir}\)\(.*${comment}\)$~\1\2/current\3~" /etc/fstab

  echo "--> remount repository"
  run_suid_helper rw_mount $name

  echo "--> updating server.conf"
  sed -i -e "s/^\(CVMFS_CREATOR_VERSION\)=.*/\1=$destination_version/" $server_conf

  echo "--> ensure binary permission settings"
  ensure_swissknife_suid $CVMFS_UNION_FS_TYPE

  # update repository information
  load_repo_config $name
}

cvmfs_server_migrate() {
  local names
  local retcode=0

  # get repository names
  check_parameter_count_for_multiple_repositories $#
  names=$(get_or_guess_multiple_repository_names $@)
  check_multiple_repository_existence "$names"

  # sanity checks
  is_root || die "Only root can migrate repositories"

  for name in $names; do

    check_repository_existence $name || { echo "The repository $name does not exist"; retcode=1; continue; }

    # get repository information
    load_repo_config $name
    creator="$(repository_creator_version $name)"

    # more sanity checks
    is_owner_or_root $name || { echo "Permission denied: Repository $name is owned by $user"; retcode=1; continue; }
    check_repository_compatibility $name "nokill" && { echo "Repository '$name' is already up-to-date."; continue; }
    health_check -r $name

    if is_stratum0 $name && is_in_transaction $name; then
      echo "Repository '$name' is currently in a transaction - migrating might"
      echo "result in data loss. Please abort or publish this transaction with"
      echo "the CernVM-FS version ($creator) that opened it."
      retcode=1
      continue
    fi

    # do the migrations...
    if [ x"$creator" = x"2.1.6" ]; then
      _migrate_2_1_6 $name
    fi

    if [ x"$creator" = x"2.1.7" -o  \
         x"$creator" = x"2.1.8" -o  \
         x"$creator" = x"2.1.9" -o  \
         x"$creator" = x"2.1.10" -o \
         x"$creator" = x"2.1.11" -o \
         x"$creator" = x"2.1.12" -o \
         x"$creator" = x"2.1.13" -o \
         x"$creator" = x"2.1.14" ];
    then
      _migrate_2_1_7 $name
    fi

    if [ x"$creator" = x"2.1.15" -o   \
         x"$creator" = x"2.1.16" -o   \
         x"$creator" = x"2.1.17" -o   \
         x"$creator" = x"2.1.18" -o   \
         x"$creator" = x"2.1.19" ] && \
         is_stratum1 $name         && \
         is_local_upstream $CVMFS_UPSTREAM_STORAGE;
    then
      _migrate_2_1_15 $name
    fi

    if [ x"$creator" = x"2.1.15" -o \
         x"$creator" = x"2.1.16" -o \
         x"$creator" = x"2.1.17" -o \
         x"$creator" = x"2.1.18" -o \
         x"$creator" = x"2.1.19" -o \
         x"$creator" = x"2.1.20" -o \
         x"$creator" = x"2.2.0-0" ];
    then
      _migrate_2_1_20 $name
    fi

    if [ x"$creator" = x"2.2.0-1" -o   \
         x"$creator" = x"2.2.1-1" -o   \
         x"$creator" = x"2.2.2-1" -o   \
         x"$creator" = x"2.2.3-1" ] && \
         is_stratum0 $name;
    then
      _migrate_2_2 $name
    fi

  done

  return $retcode
}


################################################################################


_run_catalog_migration() {
  local name="$1"
  local migration_command="$2"

  load_repo_config $name

  # more sanity checks
  is_stratum0 $name       || die "This is not a stratum 0 repository"
  is_root                 || die "Permission denied: Only root can do that"
  is_in_transaction $name && die "Repository is already in a transaction"
  health_check -r $name

  # all following commands need an open repository transaction and are supposed
  # to commit or abort it after performing the catalog migration.
  echo "Opening repository transaction"
  trap "close_transaction $name 0" EXIT HUP INT TERM
  open_transaction $name || die "Failed to open repository transaction"

  # run the catalog migration operation (must run as root!)
  echo "Starting catalog migration"
  local tmp_dir=${CVMFS_SPOOL_DIR}/tmp
  local manifest=${tmp_dir}/manifest
  migration_command="${migration_command} -t $tmp_dir -o $manifest"
  sh -c "$migration_command" || die "Fail (executed command: $migration_command)"

  # check if the catalog migration created a new revision
  if [ ! -f $manifest ]; then
    echo "Catalog migration finished without any changes"
    return 0
  fi

  # finalizing transaction
  local trunk_hash=$(grep "^C" $manifest | tr -d C)
  echo "Flushing file system buffers"
  sync

  # committing newly created revision
  echo "Signing new manifest"
  chown $CVMFS_USER $manifest        || die "chmod of new manifest failed";
  sign_manifest $name $manifest      || die "Signing failed";
  set_ro_root_hash $name $trunk_hash || die "Root hash update failed";
}


################################################################################


cvmfs_server_catalog_chown() {
  local uid_map
  local gid_map

  OPTIND=1
  while getopts "u:g:" option; do
    case $option in
      u)
        uid_map=$OPTARG
      ;;
      g)
        gid_map=$OPTARG
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command catalog-chown: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

   # get repository names
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $@)
  check_repository_existence "$name"

  # sanity checks
  [ x"$uid_map" != x"" ] && [ -f $uid_map ] || die "UID map file not found (-u)"
  [ x"$gid_map" != x"" ] && [ -f $gid_map ] || die "GID map file not found (-g)"

  load_repo_config $name

  local migrate_command="$(__swissknife_cmd dbg) migrate     \
                              -v 'chown'                     \
                              -r $CVMFS_STRATUM0             \
                              -n $name                       \
                              -u $CVMFS_UPSTREAM_STORAGE     \
                              -k $CVMFS_PUBLIC_KEY           \
                              -i $uid_map                    \
                              -j $gid_map                    \
                              -s"

  _run_catalog_migration "$name" "$migrate_command"
}


################################################################################


cvmfs_server_eliminate_hardlinks() {
  local name=
  local force=0

  # parameter handling
  OPTIND=1
  while getopts "f" option; do
    case $option in
      f)
        force=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command eliminate-hardlinks: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  # get repository name
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $@)
  check_repository_existence "$name"

  load_repo_config $name

  is_root || die "Permission denied: Only root can do that"

  if [ $force -ne 1 ]; then
    echo "This will break up all hardlink relationships that are currently"
    echo "present in '$name'. This process cannot be undone!"
    echo ""
    echo -n "Are you sure? (y/N): "

    local reply="n"
    read reply
    if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
      echo "aborted."
      exit 1
    fi
  fi

  local migrate_command="$(__swissknife_cmd dbg) migrate     \
                              -v 'hardlink'                  \
                              -r $CVMFS_STRATUM0             \
                              -n $name                       \
                              -u $CVMFS_UPSTREAM_STORAGE     \
                              -k $CVMFS_PUBLIC_KEY           \
                              -s"

  _run_catalog_migration "$name" "$migrate_command"
}


################################################################################

_update_repoinfo_cleanup() {
  local repo_name="$1"
  shift 1

  while [ $# -gt 0 ]; do
    rm -f $1 > /dev/null 2>&1
    shift 1
  done

  close_transaction $repo_name 0
}

cvmfs_server_update_repoinfo() {
  local name
  local json_file

  OPTIND=1
  while getopts "f:" option; do
    case $option in
      f)
        json_file=$OPTARG
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command update-repoinfo: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  # get repository name
  check_parameter_count_with_guessing $#
  name=$(get_or_guess_repository_name $@)

  # sanity checks
  check_repository_existence $name || die "The repository $name does not exist"
  load_repo_config $name
  is_owner_or_root $name           || die "Permission denied: Repository $name is owned by $CVMFS_USER"
  is_stratum0 $name                || die "This is not a stratum 0 repository"
  ! is_publishing $name            || die "Repository is currently publishing"
  health_check -r $name
  is_in_transaction $name && die "Cannot edit repository meta info while in a transaction"
  [ x"$json_file" = x"" ] || [ -f "$json_file" ] || die "Provided file '$json_file' doesn't exist"

  tmp_file_info=$(mktemp)
  tmp_file_manifest=$(mktemp)
  chown $CVMFS_USER $tmp_file_info $tmp_file_manifest || die "Cannot change ownership of temporary files"

  trap "_update_repoinfo_cleanup $name $tmp_file_info $tmp_file_manifest" EXIT HUP INT TERM
  open_transaction $name || die "Failed to open transaction for meta info editing"

  get_repo_info -M > $tmp_file_info || \
    die "Failed getting repository meta info for $name"
  get_repo_info -R > $tmp_file_manifest || \
    die "Failed getting repository manifest for $name"

  if [ x"$json_file" = x"" ]; then
    if [ -f $tmp_file_info ] && [ ! -s $tmp_file_info ]; then
      create_repometa_skeleton $tmp_file_info
    fi

    edit_json_until_valid $tmp_file_info
  else
    local jq_output
    if ! jq_output="$(validate_json $json_file)"; then
      die "The provided JSON file is invalid. See below:\n${jq_output}"
    fi

    cat $json_file > $tmp_file_info
  fi

  sign_manifest $name $tmp_file_manifest $tmp_file_info
}


################################################################################

_update_info_cleanup() {
  local tmp_file="$1"
  rm -f $tmp_file > /dev/null 2>&1
}

cvmfs_server_update_info() {
  local configure_apache=1
  local edit_meta_info=1

  # parameter handling
  OPTIND=1
  while getopts "pe" option; do
    case $option in
      p)
        configure_apache=0
      ;;
      e)
        edit_meta_info=0
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command update-info: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  # sanity checks
  is_root || die "only root can update meta information"

  # create info HTTP resource if not existent yet
  if ! has_global_info_path; then
    echo -n "Creating Info Resource... "
    create_global_info_skeleton || die "fail"
    echo "done"
  fi

  if [ $configure_apache -eq 1 ] && ! has_apache_config_for_global_info; then
    echo -n "Creating Apache Configuration for Info Resource... "
    create_apache_config_for_global_info || die "fail (create apache config)"
    reload_apache > /dev/null            || die "fail (reload apache)"
    echo "done"
  fi

  # manually edit the meta information file
  local tmp_file=""
  if [ $edit_meta_info -eq 1 ]; then
    # copy the meta information file for editing
    tmp_file=$(mktemp)
    trap "_update_info_cleanup $tmp_file" EXIT HUP INT TERM
    cp -f "$(get_global_info_v1_path)/meta.json" $tmp_file

    edit_json_until_valid $tmp_file || die "Aborting..."
  fi

  # update the JSON files
  echo -n "Updating global JSON information... "
  update_global_repository_info || die "fail (update repo info)"
  if [ $edit_meta_info -eq 1 ]; then
    update_global_meta_info "$tmp_file" || die "fail (update meta info)"
  fi
  echo "done"
}


################################################################################


cvmfs_server_mount() {
  local names=""
  local mount_all=0
  local retval=0

  OPTIND=1
  while getopts "a" option; do
    case $option in
      a)
        mount_all=1
      ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command mount: Unrecognized option: $1"
      ;;
    esac
  done
  shift $(($OPTIND-1))

  if [ $mount_all -eq 1 ]; then
    # sanity checks
    is_root || die "Permission Denied: need root to mount all repositories"
    names="$(ls /etc/cvmfs/repositories.d)"
  else
    # get repository name
    check_parameter_count_for_multiple_repositories $#
    names=$(get_or_guess_multiple_repository_names $@)
    check_multiple_repository_existence "$names"
  fi

  for name in $names; do
    is_stratum0        $name || continue
    is_owner_or_root   $name || { echo "Permission Denied: $name is owned by $CVMFS_USER" >&2; retval=1; continue; }
    health_check -rftq $name || { echo "Failed to mount $name"                            >&2; retval=1; continue; }
  done

  return $retval
}


################################################################################


cvmfs_server_skeleton() {
  local skeleton_dir
  local skeleton_user

  # get optional parameters
  OPTIND=1
  while getopts "o:" option
  do
    case $option in
      o)
        skeleton_user=$OPTARG
        ;;
      ?)
        shift $(($OPTIND-2))
        usage "Command skeleton: Unrecognized option: $1"
      ;;
    esac
  done

  # get skeleton destination directory
  shift $(($OPTIND-1))

  # get skeleton destination directory
  if [ $# -eq 0 ]; then
    usage "Command skeleton: Please provide a skeleton destination directory"
  fi
  if [ $# -gt 1 ]; then
    usage "Command skeleton: Too many arguments"
  fi
  skeleton_dir=$1

  # ask for the skeleton dir owern
  if [ x$skeleton_user = "x" ]; then
    read -p "Owner of $skeleton_dir [$(whoami)]: " skeleton_user
    # default value
    [ x"$skeleton_user" = x ] && skeleton_user=$(whoami)
  fi

  # sanity checks
  check_user $skeleton_user || die "No user $skeleton_user"

  # do it!
  create_repository_skeleton $skeleton_dir $skeleton_user
}


################################################################################


cvmfs_server_fix_permissions() {
  local num_overlayfs=$(find /etc/cvmfs/repositories.d -name server.conf \
    -exec grep "CVMFS_UNION_FS_TYPE=overlayfs" {} \; | wc -l)
  if [ $num_overlayfs -gt 0 ]; then
    ensure_swissknife_suid overlayfs
  fi
}


################################################################################
#                                                                              #
#                                Entry Point                                   #
#                                                                              #
################################################################################

# check that there are no traces of CernVM-FS 2.0.x which might interfere
foreclose_legacy_cvmfs

# check if there is at least a selected sub-command
if [ $# -lt 1 ]; then
  usage
fi

# check if the given sub-command is known and, if so, call it
subcommand=$1
shift
if is_subcommand $subcommand; then
  # parse the command line arguments (keep quotation marks)
  args=""
  while [ $# -gt 0 ]; do
    if echo "$1" | grep -q "[[:space:]]"; then
      args="$args \"$1\""
    else
      args="$args $1"
    fi
    shift 1
  done

  # replace a dash (-) by an underscore (_) and call the requested sub-command
  eval "cvmfs_server_$(echo $subcommand | sed 's/-/_/g') $args"
else
  usage "Unrecognized command: $subcommand"
fi
