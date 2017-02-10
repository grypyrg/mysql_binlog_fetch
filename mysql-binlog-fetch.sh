#!/bin/bash

restore_lib="/usr/share/mysql-binlog-fetch/lib.sh"
source ${restore_lib}
if [ $? -ne 0 ]; then echo "could not load lib file ${restore_lib}, quitting"; exit 1; fi


function usage
{
    echo "Usage: $0 -c config -g client_group -s host"
    echo ""
    echo "Options:"
    echo " -d directory                directory to store binlogs";
    echo "  -c mysql-binlog-fetch.cnf   configuration to read"
    echo "  -g group                    [client_group] configuration to load"
    echo "  -s target_host              hostname to fetch mysqlbinlog from"
}

if [ "$1" == "" ]; then 
    usage
    exit 1
fi

COMMAND="$0 $*"
while getopts "c:g:s:hd:" args
do
   case "$args" in
      d) directory="$OPTARG";;
      c) config="$OPTARG";;
      g) config_group="$OPTARG";;
      s) target_host="$OPTARG";;
      h) usage; exit;;
      *) die "Invalid argument provided" 1;;
   esac
done

[ -z "${target_host}"    ] && die "specify -s for specifying the target hostname" 1
[ -z "${directory}"      ] && die "specify -d for a valid directory where the binary logs will be stored" 1
[ -z "${config}"         ] && die "specify -c for a valid my.cnf configuration containing server credentials" 1
[ ! -f "${config}"       ] && die "cannot open config file {$config}" 1
[ -z "${config_group}"   ] && die "specify -g for a hostname and valid my.cnf [client_group] containing server credentials" 1

function check_process
{
    ps -p $1 2>&1 > /dev/null
    return $?
}

function cleanup
{
    check_process $(cat "${directory}/mysqlbinlog.pid")
    if [ $? -eq 0 ]; then
        print "found a running mysqlbinlog process, not removing PID file"
    else
        rm "${directory}/mysqlbinlog.pid"
    fi

    rm -f "${directory}/mysql-binlog-fetch.pid"
}

function mysqlbinlogfetch_Update () {
  in_hostname="${target_host}"
  in_mysqlbinlog_host="$(hostname)"
  in_mysqlbinlog_path="${directory}"
  in_oldest_binlog=$1
  in_newest_binlog=$2
  run_sql "CALL mysql_binlog_fetch_update('$in_hostname', '$in_mysqlbinlog_host', '$in_mysqlbinlog_path', '$in_oldest_binlog', '$in_newest_binlog')"
}


function run()
{
    print ""

    # fetch last binlog from ${directory}
    last_binlog=`ls -1 "${directory}" | grep -vE "(mysqlbinlog.pid|mysql-binlog-fetch.pid|mysql-binlog-fetch.log)" | tail -n 1`
    first_binlog=`ls -1 "${directory}" | grep -vE "(mysqlbinlog.pid|mysql-binlog-fetch.pid|mysql-binlog-fetch.log)" | head -n 1`
    if [ -z "${last_binlog}" ]; then
        # fetch oldest binlog
        last_binlog=`mysql $mysql_options -Ne "show binary logs" | head -n1 | awk '{print $1}'`
        print "Fetching all binary logs, starting with the oldest ${last_binlog}"
    else
        print "Continuing restoring from binary log ${last_binlog}"
    fi

    mysqlbinlogfetch_Update "${first_binlog}" "${last_binlog}" 

    print ""
    print "Starting mysqlbinlog ${mysql_options} --raw --read-from-remote-server --stop-never --result-file=\"${directory}/\" \"${last_binlog}\""
    mysqlbinlog ${mysql_options} --raw --read-from-remote-server --stop-never --result-file="${directory}/" "${last_binlog}" &
    echo $! > "${directory}/mysqlbinlog.pid" 
    wait %1
    return $?
}

exec >> >(tee -a ${directory}/mysql-binlog-fetch.log) 2>&1

# exiting with exit code 0 as systemctl likes this
trap '{ kill $(jobs -p) 2> /dev/null; cleanup; die "SIGNAL received, killed possible remaining mysqlbinlog process" 0;}' SIGINT SIGTERM SIGQUIT SIGKILL

print "Command: $0 $*"
print "directory     : ${directory}"
print "config        : ${config}"
print "config_group  : ${config_group}"
print "target_host   : ${target_host}"

if [ -f "${directory}/mysql-binlog-fetch.pid" ]; then
    print "mysql-binlog-fetch PID file ${directory}/mysql-binlog-fetch.pid exists, checking for running mysql-binlog-fetch.sh processes"

    check_process $(cat "${directory}/mysql-binlog-fetch.pid")
    if [ $? -eq 0 ]; then
        die "found a running mysql-binlog-fetch.sh process, quitting" 1
    else
        print "PID file seems stale, removing"
        rm -f "${directory}/mysql-binlog-fetch.pid"
    fi
fi

if [ -f "${directory}/mysqlbinlog.pid" ]; then
    print "mysqlbinlog PID file ${directory}/mysqlbinlog.pid exists, checking for running mysqlbinlog process"

    check_process $(cat "${directory}/mysqlbinlog.pid")
    if [ $? -eq 0 ]; then
        print "WARNING: found a running mysqlbinlog process, killing that process"
        kill $(cat "${directory}/mysqlbinlog.pid")
        sleep 3
        check_process $(cat "${directory}/mysqlbinlog.pid")
        if [ $? -eq 0 ]; then
            die "mysqlbinlog could not be killed successfully, quitting" 1
        fi
    else
        print "PID file seems stale, removing"
        rm -f "${directory}/mysqlbinlog.pid"
    fi
fi
echo $$ > "${directory}/mysql-binlog-fetch.pid" || die "could not create PIDfile" 1
print ""

mysql_options="--defaults-file=${config} --defaults-group-suffix=_${config_group}"

# test if we can connect to mysql AND have the right REPLICATION SLAVE privileges
mysql $mysql_options -e "SHOW GRANTS" | grep "REPLICATION CLIENT" | grep "REPLICATION SLAVE" &> /dev/null
[ $? -ne 0 ] && die "could not connect to database or do not have REPLICATION SLAVE and REPLICATION CLIENT permissions (and we don't want an ALL PRIVILEGES user to be used)" 1


errors=0
while [ ${errors} -lt 100 ]; do
    last_started=$(date "+%s")
    let time_diff=last_started-previous_starttime
    if [ $time_diff -lt 60 ]; then
        print "sleeping for 10 seconds as the previous mysqlbinlog started less than a minute ago"
        sleep 10
        continue
    fi

    run
    retval=$?
    if [ $retval -ne 0 ]; then
        let errors=errors+1
        print "ERROR: mysqlbinlog exited with non zero exit code, trying to start mysqlbinlog again (errorcounter=${errors})"
    else
        print "WARNING: mysqlbinlog exited normally, trying to start mysqlbinlog again anyway"
    fi

    previous_starttime=${last_started}
done

cleanup
print "ERROR: Exiting as we had ${errors} errors."




