#!/bin/bash

restore_lib="/usr/share/mysql-binlog-fetch/lib.sh"
source ${restore_lib}
if [ $? -ne 0 ]; then echo "could not load lib file ${restore_lib}, quitting"; exit 1; fi

function usage
{
    echo "Usage: $0 -c config -p pidfile"
    echo ""
    echo "Options:"
    echo "  -c mysql-binlog-fetch.cnf   configuration to read"
    echo "  -p pidfile                  pid file"
    echo "  -h                          this help message"
}

if [ "$1" == "" ]; then 
    usage
    exit 1
fi

COMMAND="$0 $*"
while getopts "c:p:h" args
do
    case "$args" in
      c) config="$OPTARG";;
      p) pidfile="$OPTARG";;
      h) usage; exit;;
      *) die "quitting" 1;;
    esac
done

[ -z "${config}"         ] && die "specify -c for a valid my.cnf configuration containing server credentials" 1
[ ! -f "${config}"       ] && die "cannot open config file {$config}" 1



function run_sql_host {
    sql="$2";
    group="$1";

    mysqlCmd="$cmd_mysql --defaults-file=$config --defaults-group-suffix=_${group} -Nsss ";

    # while this is useful to print, this clutters the error output a lot (especially when updating logfiles in the table)
    #print "Running SQL: $sql" 1>&2
    ${mysqlCmd} << EOS
$sql;
EOS
  mysqlretval=$?

  if [ $mysqlretval -ne 0 ]; then
    cleanup_and_die "MySQL query error" 1 ""
  fi
}

hostname=$(hostname)

function db_fetch_hosts { run_sql "SELECT DISTINCT hostname FROM mysql_binlog_fetch WHERE active=1 AND mysqlbinlog_host='${hostname}'"; }
function db_fetch_paths { run_sql "SELECT DISTINCT mysqlbinlog_path FROM mysql_binlog_fetch WHERE active=1 AND mysqlbinlog_host='${hostname}' AND hostname='$1'"; }
function db_fetch_oldest_binlog { run_sql "SELECT oldest_binlog FROM mysql_binlog_fetch WHERE mysqlbinlog_host='${hostname}' AND hostname='$1' AND mysqlbinlog_path='$2'"; }
function db_fetch_newest_binlog { run_sql "SELECT newest_binlog FROM mysql_binlog_fetch WHERE mysqlbinlog_host='${hostname}' AND hostname='$1' AND mysqlbinlog_path='$2'"; }
function db_fetch_retention { run_sql "SELECT retention_days FROM mysql_binlog_fetch WHERE mysqlbinlog_host='${hostname}' AND hostname='$1' AND mysqlbinlog_path='$2'"; }
function db_mark_error { run_sql "CALL mysql_binlog_fetch_mark_error('$1', '${hostname}', '$2', '$3')"; }
function db_update { run_sql "CALL mysql_binlog_fetch_update('$1', '$2', '$3', '$4', '$5')"; }

function host_db_fetch_newest_binlog { run_sql_host "$1" "SHOW MASTER STATUS" | awk '{print $1}'; }


function iterate() {
    for host in `db_fetch_hosts`; do
        for path in `db_fetch_paths ${host}`; do
            new_oldest_binlog=""

            [ ! -d "${path}" ] && { db_mark_error "${host}" "${path}" "directory does not exist"; continue; }

            db_oldest_binlog=$(db_fetch_oldest_binlog "${host}" "${path}")
            db_newest_binlog=$(db_fetch_newest_binlog "${host}" "${path}")

            host_db_newest_binlog=$(host_db_fetch_newest_binlog "${host}")
            [ ! -f "${path}/${host_db_newest_binlog}" ] && { db_mark_error "${host}" "${path}" "latest binary log ${host_db_newest_binlog} is not present"; continue; }

            # archiving
            retention_days=$(db_fetch_retention "${host}" "${path}")
            if [ "${retention_days}" != "NULL" ]; then
                # fetch all binlogs except the last one (which is currently used normally)
                previous_binlog=""
                for binlog in `ls -1 "${path}/" | grep -vE "(mysqlbinlog.pid|mysql-binlog-fetch.pid|mysql-binlog-fetch.log)" | head -n-1`
                do
                    let retention_seconds=retention_days*24*60*60
                    binlog_created=$(binlog_creation_timestamp "${path}/${binlog}")
                    current_time=$(date "+%s")
                    let binlog_age=current_time-binlog_created
                    if [ $binlog_age -gt $retention_seconds ]; then
                        # we remove the previous binlog
                        [ ! -z "${previous_binlog}" ] && rm -f "${path}/${previous_binlog}"
                    else
                        [ -z "${new_oldest_binlog}" ] && new_oldest_binlog="${previous_binlog}"
                    fi
                    previous_binlog=${binlog}
                done
            else
                new_oldest_binlog=$db_oldest_binlog
            fi

            db_update "${host}" "${hostname}" "${path}" "${new_oldest_binlog}" "${host_db_newest_binlog}"

        done
    done
}

pidfile_create

# exiting with 0 as systemd wants this.
trap "cleanup_and_die \"Caught interrupt, quitting\" 0" SIGINT SIGTERM SIGQUIT

while true;
do
    iterate
    sleep 600;
done


pidfile_remove


