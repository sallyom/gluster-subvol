#! /bin/bash
# vim: set ts=4 sw=4 et :

function usage() {
    echo "Usage: $0 <vol_root>"
}

sa_dir=/var/run/secrets/kubernetes.io/serviceaccount
kc_args="--server=https://kubernetes.default.svc.cluster.local --token=$(cat $sa_dir/token) --certificate-authority=$sa_dir/ca.crt"

function recycle_pv() {
    local pv=$1
    local subdir=$(kubectl $kc_args get pv/$pv \
        -ojsonpath='{.spec.flexVolume.options.dir}')
    if [ $? -ne 0 ]; then
        echo "Failed parsing PV $pv"
        return
    fi
    # make sure subdir is non-empty
    if [ "x$subdir" == "x" ]; then
        echo "Couldn't determine subdirectory for $pv"
        return
    fi
    # make sure subdir doesn't contain ..
    echo $subdir | grep -q '\.\.'
    if [ $? -ne 1 ]; then
        echo "Found .. in subdir for $pv"
        return
    fi

    local scrub=$vol_root/$subdir
    echo "= $(date) = Working on $pv"
    echo "  Scrubbing $scrub"
    test -e $scrub && rm -rf $scrub/..?* $scrub/.[!.]* $scrub/*  && test -z "$(ls -A $scrub)"
    if [ $? -ne 0 ]; then
        echo "  $(date) = Scrubbing failed. Not freeing pv... will retry later."
        return
    fi
    echo "  $(date) = Scrubbing successful. Marking PV as available."

    # Mark it available
    kubectl $kc_args patch pv/$pv --type json -p'[{"op":"remove", "path":"/spec/claimRef"}, {"op":"replace", "path":"/status/phase", "value":"Available"}]'
}

function recycle_all() {
    pvs=$(kubectl $kc_args get pv \
        -l supervol=$uuid \
        -ojsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' \
        | grep Released | cut -f1 -d' ')
    for pv in $pvs; do
        recycle_pv $pv
    done
}

vol_root=$1

if [ $# -ne 1 ]; then usage; exit 1; fi

if [ ! -f $vol_root/supervol-uuid ]; then
    echo "Unable to read UUID from volume ($vol_root/supervol-uuid)"
    exit 1;
fi
uuid=$(cat $vol_root/supervol-uuid)

echo "Recycling for supervol: $uuid"

while [ true ]; do
    recycle_all
    sleep 10
done
