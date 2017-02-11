
USE mysql_binlog_fetch;
DROP TABLE IF EXISTS mysql_binlog_fetch;
CREATE TABLE mysql_binlog_fetch (
    mysqlbinlog_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    hostname VARCHAR(128) NOT NULL,
    mysqlbinlog_host VARCHAR(128) NOT NULL,
    mysqlbinlog_path VARCHAR(256) NOT NULL,
    retention_days TINYINT UNSIGNED NULL DEFAULT NULL, 
    active BOOLEAN NOT NULL DEFAULT 1,
    error BOOLEAN NOT NULL DEFAULT 0,
    error_msg VARCHAR(256) NULL DEFAULT NULL,
    oldest_binlog VARCHAR(128) NULL DEFAULT NULL,
    newest_binlog VARCHAR(128) NULL DEFAULT NULL,
    last_updated TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (hostname, mysqlbinlog_host, mysqlbinlog_path),
    KEY (active, last_updated)
) ENGINE=INNODB;


/* STORED PROCEDURES AND FUNCTIONS */
/* NOTE: Queries are not necessarily optimized */
DELIMITER ;;


DROP PROCEDURE IF EXISTS mysql_binlog_fetch_update;;
CREATE PROCEDURE mysql_binlog_fetch_update(
    IN in_hostname VARCHAR(128),
    IN in_mysqlbinlog_host VARCHAR(128),
    IN in_mysqlbinlog_path VARCHAR(256), 
    IN in_oldest_binlog VARCHAR(128),
    IN in_newest_binlog VARCHAR(128)
)
BEGIN
    INSERT INTO mysql_binlog_fetch
            (hostname, mysqlbinlog_host, mysqlbinlog_path, active, oldest_binlog, newest_binlog, last_updated)
        VALUES
            (in_hostname, in_mysqlbinlog_host, in_mysqlbinlog_path, 1, in_oldest_binlog, in_newest_binlog, NOW())
        ON DUPLICATE KEY UPDATE
            hostname=in_hostname,
            mysqlbinlog_host=in_mysqlbinlog_host,
            mysqlbinlog_path=in_mysqlbinlog_path,
            active=1,
            oldest_binlog=in_oldest_binlog,
            newest_binlog=in_newest_binlog,
            error=0,
            error_msg=NULL,
            last_updated=NOW();
END;;


DROP PROCEDURE IF EXISTS mysql_binlog_fetch_mark_error;;
CREATE PROCEDURE mysql_binlog_fetch_mark_error(
    IN in_hostname VARCHAR(128),
    IN in_mysqlbinlog_host VARCHAR(128),
    IN in_mysqlbinlog_path VARCHAR(256),
    IN in_errormsg VARCHAR(256)
    )
BEGIN
    UPDATE mysql_binlog_fetch 
        SET error=1, error_msg=in_errormsg
        WHERE mysqlbinlog_host=in_mysqlbinlog_host
            AND hostname=in_hostname
            AND mysqlbinlog_path=in_mysqlbinlog_path;
END;;

DROP PROCEDURE IF EXISTS mysql_binlog_fetch_show_error_or_expired;;
CREATE PROCEDURE mysql_binlog_fetch_show_error_or_expired()
BEGIN
    SELECT 
        *
    FROM mysql_binlog_fetch
    WHERE 
           (active = 1 AND last_updated < NOW() - INTERVAL 1 HOUR)
        OR (active = 1 AND error = 1);
END;;

DROP PROCEDURE IF EXISTS mysql_binlog_fetch_show_running;;
CREATE PROCEDURE mysql_binlog_fetch_show_running()
BEGIN
    SELECT 
        *
    FROM mysql_binlog_fetch
    WHERE 
        active = 1
        AND error = 0
        AND last_updated >= NOW() - INTERVAL 1 HOUR;
END;;



DELIMITER ;