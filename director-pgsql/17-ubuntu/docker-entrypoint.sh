#!/usr/bin/env bash

github_bareos='raw.githubusercontent.com/bareos/bareos'
webui_admin_conf='master/webui/install/bareos/bareos-dir.d/profile/webui-admin.conf'
admin_conf='master/webui/install/bareos/bareos-dir.d/console/admin.conf.example'

if [ ! -f /etc/bareos/bareos-config.control ]; then
  tar xzf /bareos-dir.tgz --backup=simple --suffix=.before-control

  # Download default admin profile config
  if [ ! -f /etc/bareos/bareos-dir.d/profile/webui-admin.conf ]; then
    curl --silent --insecure "https://${github_bareos}/${webui_admin_conf}" \
      --output /etc/bareos/bareos-dir.d/profile/webui-admin.conf
  fi

  # Download default webUI admin config
  if [ ! -f /etc/bareos/bareos-dir.d/console/admin.conf ]; then
    curl --silent --insecure "https://${github_bareos}/${admin_conf}" \
      --output /etc/bareos/bareos-dir.d/console/admin.conf
  fi

  # Update bareos-director configs
  # Director / mycatalog & mail report
  sed -i 's#dbpassword = ""#dbpassword = '\"${DB_PASSWORD}\"'#' \
    /etc/bareos/bareos-dir.d/catalog/MyCatalog.conf
  sed -i 's#dbname = "bareos"#dbname = bareos\n  dbaddress = '\"${DB_HOST}\"'\n  dbport = '\"${DB_PORT}\"'#' \
    /etc/bareos/bareos-dir.d/catalog/MyCatalog.conf
  sed -i "s#/usr/bin/bsmtp -h localhost#/usr/bin/bsmtp -h ${SMTP_HOST}#" \
    /etc/bareos/bareos-dir.d/messages/Daemon.conf
  sed -i "s#mail = root#mail = ${ADMIN_MAIL}#" \
    /etc/bareos/bareos-dir.d/messages/Daemon.conf
  sed -i "s#/usr/bin/bsmtp -h localhost#/usr/bin/bsmtp -h ${SMTP_HOST}#" \
    /etc/bareos/bareos-dir.d/messages/Standard.conf
  sed -i "s#mail = root#mail = ${ADMIN_MAIL}#" \
    /etc/bareos/bareos-dir.d/messages/Standard.conf

  # Setup webhook
  if [ "${WEBHOOK_NOTIFICATION}" = true ]; then
    sed -i "s#/usr/bin/bsmtp -h.*#/usr/local/bin/webhook-notify %t %e %c %l %n\"#" \
      /etc/bareos/bareos-dir.d/messages/Daemon.conf
    sed -i "s#/usr/bin/bsmtp -h.*#/usr/local/bin/webhook-notify %t %e %c %l %n\"#" \
      /etc/bareos/bareos-dir.d/messages/Standard.conf
  fi

  # storage daemon
  sed -i 's#Address = .*#Address = '\""${BAREOS_SD_HOST}"\"'#' \
    /etc/bareos/bareos-dir.d/storage/File.conf
  sed -i 's#Password = .*#Password = '\""${BAREOS_SD_PASSWORD}"\"'#' \
    /etc/bareos/bareos-dir.d/storage/File.conf

  # client/file daemon
  sed -i 's#Address = .*#Address = '\""${BAREOS_FD_HOST}"\"'#' \
    /etc/bareos/bareos-dir.d/client/bareos-fd.conf
  sed -i 's#Password = .*#Password = '\""${BAREOS_FD_PASSWORD}"\"'#' \
    /etc/bareos/bareos-dir.d/client/bareos-fd.conf

  # webUI
  sed -i 's#Password = .*#Password = '\""${BAREOS_WEBUI_PASSWORD}"\"'#' \
    /etc/bareos/bareos-dir.d/console/admin.conf

  # MyCatalog Backup
  sed -i "s#/var/lib/bareos/bareos.sql#/var/lib/bareos-director/bareos.sql#" \
    /etc/bareos/bareos-dir.d/fileset/Catalog.conf

  # Control file
  touch /etc/bareos/bareos-config.control
fi

if [[ -z ${CI_TEST} ]] ; then
  # Waiting Postgresql is up
  sqlup=1
  while [ "$sqlup" -ne 0 ] ; do
    echo "Waiting for postgresql..."
    pg_isready --dbname="${DB_NAME}" --host="${DB_HOST}" --port="${DB_PORT}"
    if [ $? -ne 0 ] ; then
      sqlup=1
      sleep 5
    else
      sqlup=0
      echo "...postgresql is alive"
    fi
  done
fi

if [ ! -f /etc/bareos/bareos-db.control ] ; then
  # Waiting Postgresql is up
  sqlup=1
  while [ "$sqlup" -ne 0 ] ; do
    echo "Waiting for postgresql..."
    pg_isready --dbname="${DB_NAME}" --host="${DB_HOST}" --port="${DB_PORT}"
    if [ $? -ne 0 ] ; then
      sqlup=1
      sleep 5
    else
      sqlup=0
      echo "...postgresql is alive"
    fi
  done
  # Init Postgres DB
  export PGUSER=postgres
  export PGHOST=${DB_HOST}
  export PGPASSWORD=${DB_PASSWORD}
  psql -c 'create user bareos with createdb createrole createuser login;'
  psql -c "alter user bareos password '${DB_PASSWORD}';"
  /usr/lib/bareos/scripts/create_bareos_database 2>/dev/null
  /usr/lib/bareos/scripts/make_bareos_tables 2>/dev/null
  /usr/lib/bareos/scripts/grant_bareos_privileges 2>/dev/null

  # Control file
  touch /etc/bareos/bareos-db.control
else
  # Try Postgres upgrade
  export PGUSER=postgres
  export PGHOST=${DB_HOST}
  export PGPASSWORD=${DB_PASSWORD}
  /usr/lib/bareos/scripts/update_bareos_tables 2>/dev/null
  /usr/lib/bareos/scripts/grant_bareos_privileges 2>/dev/null
fi

# Fix permissions
find /etc/bareos ! -user bareos -exec chown bareos {} \;
chown -R bareos:bareos /var/lib/bareos

# Run Dockerfile CMD
exec "$@"
