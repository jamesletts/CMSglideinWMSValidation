#!/bin/bash


function getPropBool
{
    # $1 the file (for example, $_CONDOR_JOB_AD or $_CONDOR_MACHINE_AD)
    # $2 the key
    # echo "1" for true, "0" for false/unspecified
    # return 0 for true, 1 for false/unspecified
    val=`(grep -i "^$2 " $1 | cut -d= -f2 | sed "s/[\"' \t\n\r]//g") 2>/dev/null`
    # convert variations of true to 1
    if (echo "x$val" | grep -i true) >/dev/null 2>&1; then
        val="1"
    fi
    if [ "x$val" = "x" ]; then
        val="0"
    fi
    echo $val
    # return value accordingly, but backwards (true=>0, false=>1)
    if [ "$val" = "1" ];  then
        return 0
    else
        return 1
    fi
}


function getPropStr
{
    # $1 the file (for example, $_CONDOR_JOB_AD or $_CONDOR_MACHINE_AD)
    # $2 the key
    # echo the value
    val=`(grep -i "^$2 " $1 | cut -d= -f2 | sed "s/[\"' \t\n\r]//g") 2>/dev/null`
    echo $val
}


if [ "x$OSG_SINGULARITY_REEXEC" = "x" ]; then
    
    if [ "x$_CONDOR_JOB_AD" = "x" ]; then
        export _CONDOR_JOB_AD="NONE"
    fi
    if [ "x$_CONDOR_MACHINE_AD" = "x" ]; then
        export _CONDOR_MACHINE_AD="NONE"
    fi

    # "save" some setting from the condor ads - we need these even if we get re-execed
    # inside singularity in which the paths in those env vars are wrong
    # Seems like arrays do not survive the singularity transformation, so set them
    # explicity

    export HAS_SINGULARITY=$(getPropBool $_CONDOR_MACHINE_AD HAS_SINGULARITY)
    export OSG_SINGULARITY_PATH=$(getPropStr $_CONDOR_MACHINE_AD OSG_SINGULARITY_PATH)
    export OSG_SINGULARITY_IMAGE_DEFAULT=$(getPropStr $_CONDOR_MACHINE_AD OSG_SINGULARITY_IMAGE_DEFAULT)
    export OSG_SINGULARITY_IMAGE=$(getPropStr $_CONDOR_JOB_AD SingularityImage)
    export OSG_SINGULARITY_AUTOLOAD=$(getPropStr $_CONDOR_JOB_AD SingularityAutoLoad)
    export GLIDEIN_REQUIRED_OS=$(getPropStr $_CONDOR_MACHINE_AD GLIDEIN_REQUIRED_OS)
    export REQUIRED_OS=$(getPropStr $_CONDOR_JOB_AD REQUIRED_OS)
    export CMSSITE=$(getPropStr $_CONDOR_MACHINE_AD GLIDEIN_CMSSite)

    if [ "x$OSG_SINGULARITY_AUTOLOAD" = "x" ]; then
        # default for autoload is true
        export OSG_SINGULARITY_AUTOLOAD=1
    else
        export OSG_SINGULARITY_AUTOLOAD=$(getPropBool $_CONDOR_JOB_AD SingularityAutoLoad)
    fi
    export OSG_SINGULARITY_BIND_CVMFS=$(getPropBool $_CONDOR_JOB_AD SingularityBindCVMFS)

    #############################################################################
    #
    #  Singularity
    #
    if [ "x$HAS_SINGULARITY" = "x1" -a "x$OSG_SINGULARITY_AUTOLOAD" = "x1" -a "x$OSG_SINGULARITY_PATH" != "x" ]; then

        # If  image is not provided, load the default one
        # Custom URIs: http://singularity.lbl.gov/user-guide#supported-uris
        if [ "x$OSG_SINGULARITY_IMAGE" = "x" ]; then
            # Use OS matching to determine default; otherwise, set to the global default.
            if [ "x$GLIDEIN_REQUIRED_OS" = "xany" ]; then
                DESIRED_OS=$REQUIRED_OS
                if [ "x$DESIRED_OS" = "xany" ]; then
                    DESIRED_OS=rhel7
                fi
            else
                DESIRED_OS=$(python -c "print sorted(list(set('$REQUIRED_OS'.split(',')).intersection('$GLIDEIN_REQUIRED_OS'.split(','))))[0]" 2>/dev/null)
            fi
            if [ "x$DESIRED_OS" = "x" ]; then
                export OSG_SINGULARITY_IMAGE="$OSG_SINGULARITY_IMAGE_DEFAULT"
            elif [ "x$DESIRED_OS" = "xrhel6" ]; then
                export OSG_SINGULARITY_IMAGE="/cvmfs/singularity.opensciencegrid.org/bbockelm/cms:rhel6"
            else
                # For now, we just enumerate RHEL6 and RHEL7.
                export OSG_SINGULARITY_IMAGE="/cvmfs/singularity.opensciencegrid.org/bbockelm/cms:rhel7"
            fi
            export OSG_SINGULARITY_BIND_CVMFS=1
        fi

        # If condor_chirp is present, then copy it inside the container.
        if [ -e ../../main/condor/libexec/condor_chirp ]; then
            mkdir -p condor/libexec
            cp ../../main/condor/libexec/condor_chirp condor/libexec/condor_chirp
            mkdir -p condor/lib
            cp -r ../../main/condor/lib condor/
        fi

        # Make sure $HOME isn't shared
        OSG_SINGULARITY_EXTRA_OPTS="--home $PWD:/srv"

        # cvmfs access inside container (default, but optional)
        if [ "x$OSG_SINGULARITY_BIND_CVMFS" = "x1" ]; then
            OSG_SINGULARITY_EXTRA_OPTS="$OSG_SINGULARITY_EXTRA_OPTS --bind /cvmfs"
        fi

        # Various possible mount points to pull into the container:
        for VAR in /lfs_roots /cms /hadoop /hdfs /mnt/hadoop /etc/cvmfs/SITECONF; do
            if [ -e "$VAR" ]; then
                OSG_SINGULARITY_EXTRA_OPTS="$OSG_SINGULARITY_EXTRA_OPTS --bind $VAR"
            fi
        done

        # We want to bind $PWD to /srv within the container - however, in order
        # to do that, we have to make sure everything we need is in $PWD, most
        # notably the user-job-wrapper.sh (this script!)
        cp $0 .osgvo-user-job-wrapper.sh

        # Remember what the outside pwd dir is so that we can rewrite env vars
        # pointing to omewhere inside that dir (for example, X509_USER_PROXY)
        if [ "x$_CONDOR_JOB_IWD" != "x" ]; then
            export OSG_SINGULARITY_OUTSIDE_PWD="$_CONDOR_JOB_IWD"
        else
            export OSG_SINGULARITY_OUTSIDE_PWD="$PWD"
        fi

        # build a new command line, with updated paths
        CMD=()
        for VAR in "$@"; do
            # two seds to make sure we catch variations of the iwd,
            # including symlinked ones
            VAR=`echo " $VAR" | sed -E "s;$PWD(.*);/srv\1;" | sed -E "s;.*/execute/dir_[0-9a-zA-Z]*(.*);/srv\1;" | sed -E "s;^ ;;"`
            CMD+=("$VAR")
        done

        # If the container has disappeared on us (say, due to CVMFS issues that sprang up since the last
        # validation test), then it is too late to turn off Singularity, re-enable glexec, and run the job.
        # Best we can hope for is sleeping for 20 minutes to prevent the slot from becoming a black hole.
        if [ ! -e "$OSG_SINGULARITY_IMAGE" ]; then
            echo "Fatal worker node (`hostname` @ $CMSSITE) error: $OSG_SINGULARITY_IMAGE does not exist"
            /bin/sh -c 'exec -a "Fail due to missing singualrity image; sleep" sleep 20m'
            exit 1
        fi

        # Have the singularity wrapper scripts sit inside singularity.opensciencegrid.org.
        # If only the payload lives inside the namespace, then autofs may try to unmount it
        # (as it looks unused) and cause a dangling mount.
        PILOT_DIR=$PWD
        cd /cvmfs/singularity.opensciencegrid.org

        export OSG_SINGULARITY_REEXEC=1
        exec $OSG_SINGULARITY_PATH exec $OSG_SINGULARITY_EXTRA_OPTS \
                                   --bind $PILOT_DIR:/srv \
                                   --pwd /srv \
                                   --scratch /var/tmp \
                                   --scratch /tmp \
                                   --contain --ipc --pid \
                                   "$OSG_SINGULARITY_IMAGE" \
                                   /srv/.osgvo-user-job-wrapper.sh "${CMD[@]}"
    fi

else
    # we are now inside singularity - fix up the env
    unset TMP
    unset TEMP
    unset X509_CERT_DIR
    for key in X509_USER_PROXY X509_USER_CERT _CONDOR_MACHINE_AD _CONDOR_JOB_AD \
               _CONDOR_SCRATCH_DIR _CONDOR_CHIRP_CONFIG _CONDOR_JOB_IWD \
               OSG_WN_TMP ; do
        eval val="\$$key"
        val=`echo "$val" | sed -E "s;$OSG_SINGULARITY_OUTSIDE_PWD(.*);/srv\1;"`
        eval $key=$val
    done

    # If X509_USER_PROXY and friends are not set by the job, we might see the
    # glidein one - in that case, just unset the env var
    for key in X509_USER_PROXY X509_USER_CERT X509_USER_KEY ; do
        eval val="\$$key"
        if [ "x$val" != "x" ]; then
            if [ ! -e "$val" ]; then
                eval unset $key >/dev/null 2>&1 || true
            fi
        fi
    done

    # If the CVMFS worker node client was used, then GFAL_PLUGINS_DIR might be
    # incompatible with our local environment.
    unset GFAL_PLUGIN_DIR

    # override some OSG specific variables
    if [ "x$OSG_WN_TMP" != "x" ]; then
        export OSG_WN_TMP=/tmp
    fi

    # Add Chirp back to the environment
    if [ -e $PWD/condor/libexec/condor_chirp ]; then
        export PATH=$PWD/condor/libexec:$PATH
        export LD_LIBRARY_PATH=$PWD/condor/lib:$LD_LIBRARY_PATH
    fi

    # Some java programs have seen problems with the timezone in our containers.
    # If not already set, provide a default TZ
    if [ "x$TZ" = "x" ]; then
        export TZ="UTC"
    fi
fi 


#############################################################################
#
#  Cleanup
#

rm -f .trace-callback .osgvo-user-job-wrapper.sh >/dev/null 2>&1 || true


#############################################################################
#
#  Run the real job
#
exec "$@"
error=$?
echo "Failed to exec($error): $@" > $_CONDOR_WRAPPER_ERROR_FILE
exit 1

