#!/bin/bash

# Snapshot script for Ceph RBD and Samba vfs shadow_copy2
# Written by Laurent Barbe <laurent+autosnap@ksperis.com>
# Version 0.2 - 2014-12-01
#
# Install this file and config file in /etc/ceph/scripts/
# Edit autosnap.conf
#
# Add in crontab :
# 00 0    * * *   root    /bin/bash /etc/ceph/scripts/autosnap.sh
#
# Add in your smb.conf in global or specific share section :
# vfs objects = shadow_copy2
# shadow:snapdir = .snapshots
# shadow:sort = desc

# Config file
configfile=/etc/ceph/scripts/autosnap.conf
if [ ! -f $configfile ]; then
    echo "Config file not found $configfile"
    exit 0
fi
source $configfile


log() {
    [[ "$verbose" = "yes" ]] && echo -ne $1
    return 0
}


makesnapshot() {
    share=$1

    snapname=`date -u +GMT-%Y.%m.%d-%H.%M.%S-autosnap`

    log "\* Create snapshot for $share: @$snapname\n"
    [[ "$useenhancedio" = "yes" ]] && {
        /sbin/sysctl dev.enhanceio.$share.do_clean=1
        while [[ `cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
    }
    mountpoint -q $sharedirectory/$share \
        && sync \
        && log "synced, " \
        && xfs_freeze -f $sharedirectory/$share \
        && [[ "$useenhancedio" = "yes" ]] && {
                /sbin/sysctl dev.enhanceio.$share.do_clean=1
                while [[ `cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
                log "wb cache cleaned, "
            } \
            || log "no cache, " \
        && rbd --id=$id --keyring=$keyring snap create $rbdpool/$share@$snapname \
        && log "snapshot created.\n" 
    xfs_freeze -u $sharedirectory/$share

}


mountshadowcopy() {
    share=$1
    shadowcopylist=""
    # GET ALL EXISTING SNAPSHOT ON RBD
    snapcollection=$(rbd --id=$id --keyring=$keyring snap ls $rbdpool/$share | awk '{print $2}' | grep -- 'GMT-.*-autosnap$' | sort | sed 's/-autosnap$//g')

    datestart=$(date -u +%Y.%m.%d -d "$daterange")
    dateend=$(date -u +%Y.%m.%d)

    for snapitem in $(echo "$snapcollection")
    do
        timestamp=$(echo "$snapitem"|awk -F- '{print $2}')
        # Do inclusive range check
        if [[ "$timestamp" == "$datestart" ||
                        "$timestamp" >  "$datestart" && "$timestamp" <  "$dateend" ||
                        "$timestamp" == "$dateend" ]]
            then
                shadowcopylist=$(echo "$shadowcopylist $snapitem")
            fi
    done

    # Shadow copies to mount
    log "\* Shadow Copies to mount for $rbdpool/$share :\n$shadowcopylist\n" | sed 's/^$/-/g'

    # GET MOUNTED SNAP
    [ ! -d $sharedirectory/$share/.snapshots ] && echo "Snapshot directory $sharedirectory/$share/.snapshots does not exist. Please create it before run." && return
    snapmounted=$(mount|grep $sharedirectory/$share/.snapshots|awk '{print $3}'|awk -F/ '{print $NF}'|sed 's/^@//g')
        # Cleanup abandoned snap mountpoints                                                                                                                                                                      
        for mountdir in $(ls "$sharedirectory/$share/.snapshots"|sed 's/^@//g')
        do
            if [[ ! $(echo "$snapmounted"|grep "$mountdir") ]]
            then
                echo "$sharedirectory/$share/.snapshots/@$mountdir exists but not mounted, removing."
                rmdir "$sharedirectory/$share/.snapshots/@$mountdir"
            fi
        done

    # Umount Snapshots not selected in shadowcopylist
    for snapshot in $snapmounted; do
        mountdir=$sharedirectory/$share/.snapshots/@$snapshot
        echo "$shadowcopylist" | grep -q "$snapshot" || {
            umount $mountdir \
            && rmdir $mountdir \
            && rbd unmap /dev/rbd/$rbdpool/$share@$snapshot-autosnap
        }
    done

    # Mount snaps in $shadowcopylist not already mount
    for snapshot in $shadowcopylist; do
        mountdir=$sharedirectory/$share/.snapshots/@$snapshot
        mountpoint -q $mountdir || {
            [ ! -d $mountdir ] && mkdir $mountdir
            rbd showmapped | awk '{print $4}' | grep "^$" || rbd --id=$id --keyring=$keyring map $rbdpool/$share@$snapshot-autosnap > /dev/null
            mount $mntoptions /dev/rbd/$rbdpool/$share@$snapshot-autosnap $mountdir
        }
    done

}

cleansnapshot() {
    share=$1

    snapcollection=$(rbd --id=$id --keyring=$keyring snap ls $rbdpool/$share | awk '{print $2}' | grep -- 'GMT-.*-autosnap$' | sort )

    for snapshot in $snapcollection; do
        datesnap=`echo $snapshot | cut -f2 -d'-'`
        if [[ "$datesnap" < `date -u +%Y.%m.%d -d "$snapretention day ago"` ]]; then
            if ! ( [[ "$keepmonthlyretention" = "yes" ]] && [[ "$datesnap" = *.01 ]] ); then
                log "\* Delete snapshot for $share: @$snapshot\n"
                rbd --id=$id --keyring=$keyring snap rm $rbdpool/$share@$snapshot
                sleep 600
            fi
        fi
    done

}


if [[ "$snapshotenable" = "yes" ]]; then
    log "---- SNAPSHOT ENABLED ----\n"
    for share in $sharelist; do
        makesnapshot $share
    done
fi

[[ "$snapshotenable" = "yes" ]] && [[ "$mountshadowcopyenable" = "yes" ]] && sleep 60

if [[ "$mountshadowcopyenable" = "yes" ]]; then
    log "---- MOUNT SHADOW COPY ENABLED ----\n"
    for share in $sharelist; do
        mountshadowcopy $share
    done
fi

if [[ "$cleansnapshotenable" = "yes" ]]; then
    log "---- CLEAN SNAPSHOT ENABLED ----\n"
    for share in $sharelist; do
        cleansnapshot $share
    done
fi

