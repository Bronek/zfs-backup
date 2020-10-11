#!/bin/bash -e
#set -x

POSITIONAL=()
CONFIRM=0
DRYRUN=0
VERBOSE=0

# parse options
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -y|--yes)
      CONFIRM=1
      shift
      ;;
    -n|--dry-run)
      DRYRUN=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

# -y and -n are clashing, -n wins
if [[ $DRYRUN -gt 0 ]]; then
  CONFIRM=0
fi

help() {
  >&2 echo "Usage: $0 [-y|--yes][-n|--dry-run][-v|--verbose] source destination [@snapshot]"
  >&2 echo
  >&2 echo "Copy last (or selected) snapshot from source to destination ZFS filesystem"
  >&2 echo "Will traverse all nested filesystems and volumes like 'zfs send -R' does"
  >&2 echo
  >&2 echo "Parameters:"
  >&2 echo "  -d, --dry-run  No-op. Performs 'zfs send -n ... | cat'. Implied if -y is not set"
  >&2 echo "  -y, --yes      Do perform actual 'zfs send ... | zfs receive'"
  >&2 echo "  -v, --verbose  Show progress when sending data, i.e. 'zfs send -v ...'"
  >&2 echo
  >&2 echo "Notes:"
  >&2 echo "  - @snapshot must start with @"
  >&2 echo "  - destination filesystem will be rolledback before receive"
  >&2 echo "  - destination must be a locally imported ZFS pool"
  >&2 echo "  - execution will abort on first error"
  exit 1
}

read_type() {
  echo "$(zfs get type "${1}" -H -o value)"
}

check_snapshot() {
  TYPE=$(read_type "${1}${2}")
  if [[ -z "$TYPE" ]]; then
    exit 1
  fi
  if [ "$TYPE" != "snapshot" ]; then
    >&2 echo "'${1}${2}' is not a snapshot"
    exit 1
  fi
}

find_snapshot() {
  RES="@"$(zfs list -t snapshot ${1} -o name -H | tail -1 | cut -d@ -f2)
  if [ "$RES" == "@" ]; then
    >&2 echo "'${1}' has no snapshots"
    exit 1
  fi
  echo "$RES"
}

SOURCE=
DEST=
SNAP=

# read source, destination and optional snapshot name
if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
  help
else
  SOURCE="${POSITIONAL[0]}"
  DEST="${POSITIONAL[1]}"
  if [[ ${#POSITIONAL[@]} -eq 3 ]]; then
    SNAP="${POSITIONAL[2]}"
    check_snapshot ${SOURCE} ${SNAP}
  elif [[ ${#POSITIONAL[@]} -eq 2 ]]; then
    SNAP=
  else
    help
  fi
fi

OBJECTS=$(zfs list -t volume,filesystem -o name -H -r ${SOURCE})
dryrun=""
if [[ $CONFIRM -lt 1 ]]; then
  dryrun="-n"
fi

verbose=""
if [[ $VERBOSE -eq 1 ]]; then
  verbose="-v"
fi

for i in ${OBJECTS}; do
  now=${SNAP}
  if [[ -z "$now" ]]; then
    now=$(find_snapshot $i)
  fi

  j=$(echo $i | sed -E "s|^${SOURCE}|${DEST}|")
  recv="cat"
  if [[ $CONFIRM -eq 1 ]]; then
    recv="zfs receive $j"
  fi
  show="zfs receive $j"

  TYPE=$(read_type $j)
  if [[ -z "$TYPE" ]]; then
    echo "! creating '$j'"
    echo "# zfs send $dryrun $verbose -R -w ${i}${now} | ${recv[@]}"
    zfs send $dryrun $verbose -R -w "${i}${now}" | ${recv[@]}
  else
    old=$(find_snapshot $j)
    if [[ "$old" == "$now" ]]; then
      echo ". '${j}' is up to date"
    else
      echo "+ updating '$j'"
      echo "# zfs rollback ${j}${old}"
      if [[ $CONFIRM -eq 1 ]]; then
        zfs rollback "${j}${old}"
      fi
      echo "# zfs send $dryrun $verbose -p -w -I $old ${i}${now} | ${show[@]}"
      zfs send $dryrun $verbose -p -w -I $old "${i}${now}" | ${recv[@]}
    fi
  fi
done

