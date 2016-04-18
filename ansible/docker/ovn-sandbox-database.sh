#!/bin/bash

run() {
    (cd "$sandbox" && "$@") || exit 1
}


#srcdir=/ovs
#schema=$srcdir/vswitchd/vswitch.ovsschema
#ovnsb_schema=$srcdir/ovn/ovn-sb.ovsschema
#ovnnb_schema=$srcdir/ovn/ovn-nb.ovsschema
#vtep_schema=$srcdir/vtep/vtep.ovsschema

#srcdir=/ovs
schema=/usr/share/openvswitch/vswitch.ovsschema
ovnsb_schema=/usr/share/openvswitch/ovn-sb.ovsschema
ovnnb_schema=/usr/share/openvswitch/ovn-nb.ovsschema
#vtep_schema=$srcdir/vtep/vtep.ovsschema

controller_ip=$1
device=$2

#
# IP related code start
#
declare -a IP_CIDR_ARRAY
declare -A IP_NETMASK_TABLE

function get_ip_cidrs {
    dev=$1

    i=0
    IFS=$'\n'
    #echo "$dev ip cidrs:"
    #echo "---------------------------"
    for inet in `ip addr show $dev | grep -e 'inet\b'` ; do
        local ip_cidr=`echo $inet | \
            sed -n  -e  's%.*inet \(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}/[0-9]\+\) .*%\1%p'`

        IFS=' '
        read ip_addr netmask <<<$(echo $ip_cidr | sed -e 's/\// /')
        IP_CIDR_ARRAY[i]=$ip_cidr
        IP_NETMASK_TABLE[$ip_addr]=$netmask

        #echo "    cidr $ip_cidr"
        ((i+=1))
    done

    #echo IP_CIDR_ARRAY: ${IP_CIDR_ARRAY[@]}
}


function in_array # ( keyOrValue, arrayKeysOrValues )
{
    local elem=$1

    IFS=' '
    local i
    for i in "${@:2}"; do
        #echo "$i == $elem"
        [[ "$i" == "$elem" ]] && return 0;
    done

    return 1
}


function get_ip_from_cidr {
    local cidr=$1
    echo $cidr | cut -d'/' -f1
}

function get_netmask_from_cidr {
    local cidr=$1
    echo $cidr | cut -d'/' -f2
}


function ip_addr_add {
    local ip=$1
    local dev=$2

    if in_array $ip ${IP_CIDR_ARRAY[@]} ; then
        echo "$ip is already on $dev"
        return
    fi

    echo "Add $ip to $dev"
    sudo ip addr add $ip dev $dev
}


function ip_cidr_fixup {
    local ip=$1
    if [[ ! "$ip" =~ "/" ]] ; then
        echo $ip"/32"
        return
    fi

    echo $ip
}

#
# IP related code end
#

# Create sandbox.
sandbox_name="controller-sandbox"

sandbox=`pwd`/$sandbox_name

# Get ip addresses on net device
get_ip_cidrs $device
host_ip=`ip_cidr_fixup $host_ip`

mkdir $sandbox_name

# Set up environment for OVS programs to sandbox themselves.
cat > $sandbox_name/sandbox.rc <<EOF
OVS_RUNDIR=$sandbox; export OVS_RUNDIR
OVS_LOGDIR=$sandbox; export OVS_LOGDIR
OVS_DBDIR=$sandbox; export OVS_DBDIR
OVS_SYSCONFDIR=$sandbox; export OVS_SYSCONFDIR
EOF

. $sandbox_name/sandbox.rc

# A UUID to uniquely identify this system.  If one is not specified, a random
# one will be generated.  A randomly generated UUID will be saved in a file
# 'ovn-uuid'.
OVN_UUID=${OVN_UUID:-}

function configure_ovn {
    echo "Configuring OVN"

    if [ -z "$OVN_UUID" ] ; then
        if [ -f $OVS_RUNDIR/ovn-uuid ] ; then
            OVN_UUID=$(cat $OVS_RUNDIR/ovn-uuid)
        else
            OVN_UUID=$(uuidgen)
            echo $OVN_UUID > $OVS_RUNDIR/ovn-uuid
        fi
    fi
}


function init_ovsdb_server {

    server_name=$1
    db=$2
    db_sock=`basename $2`

    #Wait for ovsdb-server to finish launching.
    echo -n "Waiting for $server_name to start..."
    while test ! -e "$sandbox"/$db_sock; do
        sleep 1;
    done
    echo "  Done"

    run ovs-vsctl --db=$db --no-wait -- init
}



function start_ovs {
    # Create database and start ovsdb-server.
    echo "Starting OVS"

    CON_IP=`get_ip_from_cidr $controller_ip`
    echo "controller ip: $CON_IP"

    SANDBOX_BIND_IP=""
    EXTRA_DBS=""
    OVSDB_REMOTE=""

            touch "$sandbox"/.conf-nb.db.~lock~
            touch "$sandbox"/.conf-sb.db.~lock~
            run ovsdb-tool create conf-nb.db "$schema"
            run ovsdb-tool create conf-sb.db "$schema"

            touch "$sandbox"/.ovnsb.db.~lock~
            touch "$sandbox"/.ovnnb.db.~lock~
            run ovsdb-tool create ovnsb.db "$ovnsb_schema"
            run ovsdb-tool create ovnnb.db "$ovnnb_schema"

            ip_addr_add $controller_ip $device
            SANDBOX_BIND_IP=$controller_ip

            OVSDB_REMOTE="ptcp\:6640\:$CON_IP"

            cat >> $sandbox_name/sandbox.rc <<EOF
OVN_NB_DB=unix:$sandbox/db-nb.sock; export OVN_NB_DB
OVN_SB_DB=unix:$sandbox/db-sb.sock; export OVN_SB_DB
EOF
            . $sandbox_name/sandbox.rc

            # Northbound db server
            prog_name='ovsdb-server-nb'
            run ovsdb-server --detach --no-chdir --pidfile=$prog_name.pid \
                --unixctl=$prog_name.ctl \
                -vconsole:off -vsyslog:off -vfile:info \
		--log-file=$prog_name.log \
                --remote="p$OVN_NB_DB" \
                conf-nb.db ovnnb.db
            pid=`cat $sandbox_name/$prog_name.pid`
            mv $sandbox_name/$prog_name.ctl $sandbox_name/$prog_name.$pid.ctl

            # Southbound db server
            prog_name='ovsdb-server-sb'
            run ovsdb-server --detach --no-chdir --pidfile=$prog_name.pid \
                --unixctl=$prog_name.ctl \
                -vconsole:off -vsyslog:off -vfile:info \
		--log-file=$prog_name.log \
                --remote="p$OVN_SB_DB" \
                --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
                conf-sb.db ovnsb.db
            pid=`cat $sandbox_name/$prog_name.pid`
            mv $sandbox_name/$prog_name.ctl $sandbox_name/$prog_name.$pid.ctl

    #Add a small delay to allow ovsdb-server to launch.
    sleep 0.1

        init_ovsdb_server "ovsdb-server-nb" $OVN_NB_DB
        init_ovsdb_server "ovsdb-server-sb" $OVN_SB_DB

        ovs-vsctl --db=$OVN_SB_DB --no-wait \
            -- set open_vswitch .  manager_options=@uuid \
            -- --id=@uuid create Manager target="$OVSDB_REMOTE" inactivity_probe=0

    cat >> $sandbox_name/sandbox.rc <<EOF
SANDBOX_BIND_IP=$SANDBOX_BIND_IP; export SANDBOX_BIND_IP
SANDBOX_BIND_DEV=$device; export SANDBOX_BIND_DEV
EOF

}


function start_ovn {
    echo "Starting OVN northd"

    run ovn-northd  --no-chdir --pidfile \
              -vconsole:off -vsyslog:off -vfile:info --log-file \
              --ovnnb-db=$OVN_NB_DB \
              --ovnsb-db=$OVN_SB_DB
}


configure_ovn

start_ovs

start_ovn
