#!/bin/bash -e
#set -x

POSITIONAL=()
CONFIRM=0
DRYRUN=0
VERBOSE=0

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

if [[ $DRYRUN -gt 0 ]]; then
  CONFIRM=0
fi

help() {
  >&2 echo "Usage:"
  >&2 echo "$0 [-y|--yes][-n|--dry-run][-v|--verbose] source destination [@snapshot]"
  exit 1
}

read_type() {
  echo "$(zfs get type "${1}" -H -o value)"
}

check_snapshot() {
  TYPE=$(read_type "${1}${2}")
  if [ "${TYPE}" != "snapshot" ]; then
    >&2 echo "'${1}${2}' is not a snapshot"
    exit 1
  fi
}

find_snapshot() {
  RES="@"$(zfs list -t snapshot ${1} -o name -H | tail -1 | cut -d@ -f2)
  if [ "${RES}" == "@" ]; then
    >&2 echo "'${1}' has no snapshots"
    exit 1
  fi
  echo "${RES}"
}

SOURCE=
DEST=
SNAP=

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

for i in ${OBJECTS}; do
  dryrun=""
  if [[ $CONFIRM -lt 1 ]]; then
    dryrun="-n"
  fi

  verbose=""
  if [[ $VERBOSE -eq 1 ]]; then
    verbose="-v"
  fi

  now=${SNAP}
  if [[ -z "$now" ]]; then
    now=$(find_snapshot $i)
  fi

  j=$(echo $i | sed -E "s|^${SOURCE}|${DEST}|")
  recv="cat"
  if [[ $CONFIRM -eq 1 ]]; then
    recv="zfs receive $j"
  fi

  TYPE=$(read_type $j)
  if [[ -z "$TYPE" ]]; then
    echo "! creating '$j'"
    zfs send $dryrun $verbose -R -w "${i}${now}" | ${recv[@]}
  else
    old=$(find_snapshot $j)
    if [[ "$old" == "$now" ]]; then
      echo ". '${j}' is up to date"
    else
      echo "+ updating '$j'"
      if [[ $CONFIRM -eq 1 ]]; then
        zfs rollback "${j}${old}"
      fi
      zfs send $dryrun $verbose -p -w -I $old "${i}${now}" | ${recv[@]}
    fi
  fi
done

