###########################################################################################

function print_date () {
  date '+%Y-%m-%d %H-%M-%S'
}

function print () {
  echo "[$(print_date)] $1"
}

function die()
{
   retval=${2:-1}
   print "ERROR (${retval}): ${1}" 1>&2
   exit ${retval}
}

function pidfile_create() {

  [[ -z "${pidfile}" ]] && die "specify -p pidfile" 1

  # verify that no backup is already running
  if [ -f "${pidfile}" ]; then
    read pid < "${pidfile}"
    [ -d "/proc/${pid}" ] && die "another instance is already running (pid: ${pid})" 1
  fi

  echo $$ > "${pidfile}" || die "failed to create pidfile (${pidfile})" 1
}

function pidfile_remove() {
  /bin/rm -f "${pidfile}"
}

function cleanup_and_die() {
  pidfile_remove
  die "$1" "$2"
}

cmd_mysql="/usr/bin/mysql";

# run a statement on centralized backup database
function run_sql
{
  sql="$1";
  options="$2";
  sqlfile="$3";

  if [ -z "$options" ]; then
    options="-Nsss";
  fi
  mysqlCmd="$cmd_mysql --defaults-file=$config --defaults-group-suffix=_metadata";

  if [ "${sqlfile}" == "" ]; then
    # while this is useful to print, this clutters the error output a lot (especially when updating logfiles in the table)
    #print "Running SQL: $sql" 1>&2
    ${mysqlCmd} ${options} << EOS
$sql;
EOS
    mysqlretval=$?
  else
    cat "${sqlfile}" | ${mysqlCmd} ${options}
    mysqlretval=$?
  fi

  if [ $mysqlretval -ne 0 ]; then
    die "MySQL query error" 1 ""
  fi
}

debug=0
function debug {
  if [ ${debug} -eq 1 ]; then
    print "breakpoint detected, press [enter] to continue."
    read bleh
  fi
}

function binlog_creation_timestamp {
    file=$1
    date --date="`mysqlbinlog \"${file}\" | head -n 10 | grep -E '^#' | grep -v '# at ' | awk '{gsub(\"#\", "", \$1); print \$1, \$2}'`"  "+%s"
}
