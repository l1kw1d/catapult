#!/usr/bin/env bash



# variables inbound from provisioner args
# $1 => environment
# $2 => repository
# $3 => gpg key
# $4 => instance
# $5 => software_validation



echo -e "==> Updating existing packages and installing utilities"
start=$(date +%s)
# only allow authentication via ssh key pair
# suppress this - There were 34877 failed login attempts since the last successful login.
if ! grep -q "PasswordAuthentication no" "/etc/ssh/sshd_config"; then
   sudo bash -c 'echo "PasswordAuthentication no" >> /etc/ssh/sshd_config'
fi
sudo systemctl stop sshd.service
sudo systemctl start sshd.service
# update yum
sudo yum update -y
# git clones
sudo yum install -y git
# parse yaml
sudo easy_install pip
sudo pip install --upgrade pip
sudo pip install shyaml --upgrade
configuration=$(gpg --batch --passphrase ${3} --decrypt /catapult/secrets/configuration.yml.gpg)
gpg --verbose --batch --yes --passphrase ${3} --output /catapult/secrets/id_rsa --decrypt /catapult/secrets/id_rsa.gpg
gpg --verbose --batch --yes --passphrase ${3} --output /catapult/secrets/id_rsa.pub --decrypt /catapult/secrets/id_rsa.pub.gpg
chmod 700 /catapult/secrets/id_rsa
chmod 700 /catapult/secrets/id_rsa.pub
# forward root's mail to company mail
sudo cat > "/root/.forward" << EOF
"$(echo "${configuration}" | shyaml get-value company.email)"
EOF
end=$(date +%s)
echo "==> completed in ($(($end - $start)) seconds)"


echo -e "\n\n\n==> Configuring time"
start=$(date +%s)
source /catapult/provisioners/redhat/modules/time.sh
provisionstart=$(date +%s)
sudo touch /catapult/provisioners/redhat/logs/mysql.log
end=$(date +%s)
echo "==> completed in ($(($end - $start)) seconds)"


echo -e "\n\n\n==> Installing Drush and WP-CLI"
start=$(date +%s)
sudo yum install -y php-cli
sudo yum install -y mariadb
# install drush
if [ ! -f /usr/bin/drush  ]; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
    ln -s /usr/local/bin/composer /usr/bin/composer
    git clone https://github.com/drush-ops/drush.git /usr/local/src/drush
    cd /usr/local/src/drush
    git checkout 7.0.0-rc1
    ln -s /usr/local/src/drush/drush /usr/bin/drush
    composer install
fi
drush --version
end=$(date +%s)
echo "==> completed in ($(($end - $start)) seconds)"


echo -e "\n\n\n==> Installing MySQL"
start=$(date +%s)
# install mariadb
sudo yum -y install mariadb mariadb-server
sudo systemctl enable mariadb.service
sudo systemctl start mariadb.service
end=$(date +%s)
echo -e "\n==> completed in ($(($end - $start)) seconds)"


echo -e "\n\n\n==> Configuring git repositories (This may take a while...)"
start=$(date +%s)
source /catapult/provisioners/redhat/modules/git.sh
end=$(date +%s)
echo -e "\n==> completed in ($(($end - $start)) seconds)"


echo -e "\n\n\n==> Configuring MySQL"
start=$(date +%s)
# configure mysql conf so user/pass isn't logged in shell history or memory
sudo cat > "/catapult/provisioners/redhat/installers/${1}.cnf" << EOF
[client]
host = "localhost"
user = "root"
password = "$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.root_password)"
EOF
dbconf="/catapult/provisioners/redhat/installers/${1}.cnf"

# only set root password on fresh install of mysql
if mysqladmin --defaults-extra-file=$dbconf ping 2>&1 | grep -q "failed"; then
    sudo mysqladmin -u root password "$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.root_password)"
fi

# disable remote root login
mysql --defaults-extra-file=$dbconf -e "DELETE FROM mysql.user WHERE user='root' AND host NOT IN ('localhost', '127.0.0.1', '::1')"
# remove anonymous user
mysql --defaults-extra-file=$dbconf -e "DELETE FROM mysql.user WHERE user=''"

# configure outside access to mysql
iptables -I INPUT -p tcp --dport 3306 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -I OUTPUT -p tcp --sport 3306 -m state --state ESTABLISHED -j ACCEPT

# clear out all users except root
mysql --defaults-extra-file=$dbconf -e "DELETE FROM mysql.user WHERE user!='root'"

# create an array of domainvaliddbnames
while IFS='' read -r -d '' key; do
    domainvaliddbname=$(echo "$key" | grep -w "domain" | cut -d ":" -f 2 | tr -d " " | tr "." "_")
    domainvaliddbnames+=(${1}_${domainvaliddbname})
done < <(echo "${configuration}" | shyaml get-values-0 websites.apache)
# cleanup databases from domainvaliddbnames array
for database in $(mysql --defaults-extra-file=$dbconf -e "show databases" | egrep -v "Database|mysql|information_schema|performance_schema"); do
    if ! [[ ${domainvaliddbnames[*]} =~ $database ]]; then
        echo "Cleaning up websites that no longer exist..."
        mysql --defaults-extra-file=$dbconf -e "DROP DATABASE $database";
    fi
done

# create mysql user
# @todo user per db? 16 char limit
mysql --defaults-extra-file=$dbconf -e "GRANT USAGE ON *.* TO '$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.user)'@'%'"
mysql --defaults-extra-file=$dbconf -e "DROP USER '$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.user)'@'%'"
mysql --defaults-extra-file=$dbconf -e "CREATE USER '$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.user)'@'%' IDENTIFIED BY '$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.user_password)'"

# create maintenance user
mysql --defaults-extra-file=$dbconf -e "GRANT USAGE ON *.* TO 'maintenance'@'%'"
mysql --defaults-extra-file=$dbconf -e "DROP USER 'maintenance'@'%'"
mysql --defaults-extra-file=$dbconf -e "CREATE USER 'maintenance'@'%'"

# flush privileges
mysql --defaults-extra-file=$dbconf -e "FLUSH PRIVILEGES"

# this overwrite all items in cron, we then add databases below
cat <(echo "* 3 * * * mysqlcheck -u maintenance --all-databases --auto-repair --optimize") | crontab -

echo "${configuration}" | shyaml get-values-0 websites.apache |
while IFS='' read -r -d '' key; do

    domain=$(echo "$key" | grep -w "domain" | cut -d ":" -f 2 | tr -d " ")
    domainvaliddbname=$(echo "$key" | grep -w "domain" | cut -d ":" -f 2 | tr -d " " | tr "." "_")
    software=$(echo "$key" | grep -w "software" | cut -d ":" -f 2 | tr -d " ")
    software_dbprefix=$(echo "$key" | grep -w "software_dbprefix" | cut -d ":" -f 2 | tr -d " ")
    software_workflow=$(echo "$key" | grep -w "software_workflow" | cut -d ":" -f 2 | tr -d " ")
    software_dbexist=$(mysql --defaults-extra-file=$dbconf -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '${1}_${domainvaliddbname}'")

    if [ "${1}" = "production" ]; then
        echo -e "\nNOTICE: ${domain}"
    else
        echo -e "\nNOTICE: ${1}.${domain}"
    fi
    if ! test -n "${software}"; then
        echo -e "\t* this website has no software setting, skipping database workflow"
    else
        # respect software_workflow option
        if ([ "${1}" = "production" ] && [ "${software_workflow}" = "downstream" ] && [ "${software_dbexist}" != "" ]) || ([ "${1}" = "test" ] && [ "${software_workflow}" = "upstream" ] && [ "${software_dbexist}" != "" ]); then
            echo -e "\t* workflow is set to ${software_workflow} and this is the ${1} environment, performing a database backup"
            # database dumps are always committed to the develop branch to respect software_workflow
            cd "/var/www/repositories/apache/${domain}" && git checkout develop
            if ! [ -f /var/www/repositories/apache/${domain}/_sql/$(date +"%Y%m%d").sql ]; then
                mkdir -p "/var/www/repositories/apache/${domain}/_sql"
                mysqldump --defaults-extra-file=$dbconf --single-transaction --quick ${1}_${domainvaliddbname} > /var/www/repositories/apache/${domain}/_sql/$(date +"%Y%m%d").sql
                cd "/var/www/repositories/apache/${domain}" && git config --global user.name "Catapult" | sed "s/^/\t/"
                cd "/var/www/repositories/apache/${domain}" && git config --global user.email "$(echo "${configuration}" | shyaml get-value company.email)" | sed "s/^/\t/"
                cd "/var/www/repositories/apache/${domain}" && git add "/var/www/repositories/apache/${domain}/_sql/$(date +"%Y%m%d").sql" | sed "s/^/\t/"
                cd "/var/www/repositories/apache/${domain}" && git commit -m "Catapult auto-commit." | sed "s/^/\t/"
                cd "/var/www/repositories/apache/${domain}" && sudo ssh-agent bash -c "ssh-add /catapult/secrets/id_rsa; git push origin develop" | sed "s/^/\t/"
            else
                echo -e "\t\ta backup was already performed today"
            fi
            # after verifying database dump, checkout the correct branch again
            cd "/var/www/repositories/apache/${domain}" && git checkout $(echo "${configuration}" | shyaml get-value environments.${1}.branch)
        else
            echo -e "\t* workflow is set to ${software_workflow} and this is the ${1} environment, performing a database restore"
            # drop the database
            # the loop is necessary just in case the database doesn't yet exist
            for database in $(mysql --defaults-extra-file=$dbconf -e "show databases" | egrep -v "Database|mysql|information_schema|performance_schema"); do
                if [ ${database} = ${1}_${domainvaliddbname} ]; then
                    mysql --defaults-extra-file=$dbconf -e "DROP DATABASE ${1}_${domainvaliddbname}";
                fi
            done
            # create database
            mysql --defaults-extra-file=$dbconf -e "CREATE DATABASE ${1}_${domainvaliddbname}"
            # confirm we have a usable database backup
            if ! [ -d "/var/www/repositories/apache/${domain}/_sql" ]; then
                echo -e "\t* ~/_sql directory does not exist, ${software} will not function"
            else
                echo -e "\t* ~/_sql directory exists, looking for a valid database dump to restore from"
                filenewest=$(ls "/var/www/repositories/apache/${domain}/_sql" | grep -E ^[0-9]{8}\.sql$ | sort -n | tail -1)
                for file in /var/www/repositories/apache/${domain}/_sql/*.*; do
                    if [[ "${file}" != *.sql ]]; then
                        echo -e "\t\t[invalid] [ ].sql [ ]YYYYMMDD.sql [ ]newest => $file"
                    elif ! [[ "$(basename "${file}")" =~ ^[0-9]{8}.sql$ ]]; then
                        echo -e "\t\t[invalid] [x].sql [ ]YYYYMMDD.sql [ ]newest => $file"
                    elif [[ "$(basename "$file")" != "${filenewest}" ]]; then
                        echo -e "\t\t[invalid] [x].sql [x]YYYYMMDD.sql [ ]newest => $file"
                    else
                        echo -e "\t\t[valid]   [x].sql [x]YYYYMMDD.sql [x]newest => $file"
                        echo -e "\t\t\trestoring..."
                        # match http:// and optionally www. then replace with http:// + optionally www. + either dev., test., or the production domain
                        if [[ "${software}" != "wordpress" ]]; then
                            echo -e "\t* updating ${software} database with ${1}.${domain} URLs"
                            sed -r -e "s/:\/\/(www\.)?${domain}/:\/\/\1${1}\.${domain}/g" "/var/www/repositories/apache/${domain}/_sql/$(basename "$file")" > "/var/www/repositories/apache/${domain}/_sql/${1}.$(basename "$file")"
                        else
                            cp "/var/www/repositories/apache/${domain}/_sql/$(basename "$file")" "/var/www/repositories/apache/${domain}/_sql/${1}.$(basename "$file")"
                        fi
                        mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} < "/var/www/repositories/apache/${domain}/_sql/${1}.$(basename "$file")"
                        rm -f "/var/www/repositories/apache/${domain}/_sql/${1}.$(basename "$file")"
                        if [[ "${software}" = "drupal6" ]]; then
                            echo -e "\t* resetting ${software} admin password..."
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}users SET name='admin', mail='$(echo "${configuration}" | shyaml get-value company.email)', pass=MD5('$(echo "${configuration}" | shyaml get-value environments.${1}.software.drupal.admin_password)'), status='1' WHERE uid = 1;"
                        fi
                        if [[ "${software}" = "drupal7" ]]; then
                            echo -e "\t* resetting ${software} admin password..."
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}users SET name='admin', mail='$(echo "${configuration}" | shyaml get-value company.email)', status='1' WHERE uid = 1;"
                        fi
                        if [[ "${software}" = "wordpress" ]]; then
                            echo -e "\t* resetting ${software} admin password..."
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}users SET user_login='admin', user_email='$(echo "${configuration}" | shyaml get-value company.email)', user_pass=MD5('$(echo "${configuration}" | shyaml get-value environments.${1}.software.wordpress.admin_password)'), user_status='0' WHERE id = 1;"
                            echo -e "\t* updating ${software} database with ${1}.${domain} URLs"
                            php /catapult/provisioners/redhat/installers/wp-cli.phar --path="/var/www/repositories/apache/${domain}/" search-replace "${domain}" "${1}.${domain}" | sed "s/^/\t\t/"
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}options SET option_value='$(echo "${configuration}" | shyaml get-value company.email)' WHERE option_name = 'admin_email';"
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}options SET option_value='http://${1}.${domain}' WHERE option_name = 'home';"
                            mysql --defaults-extra-file=$dbconf ${1}_${domainvaliddbname} -e "UPDATE ${software_dbprefix}options SET option_value='http://${1}.${domain}' WHERE option_name = 'siteurl';"
                        fi
                    fi
                done
            fi
        fi
        # grant mysql user to database
        mysql --defaults-extra-file=$dbconf -e "GRANT ALL ON ${1}_${domainvaliddbname}.* TO '$(echo "${configuration}" | shyaml get-value environments.${1}.servers.redhat_mysql.mysql.user)'@'%'";
        # grant maintenance user to database
        mysql --defaults-extra-file=$dbconf -e "GRANT ALL ON ${1}_${domainvaliddbname}.* TO 'maintenance'@'%'";
        # flush privileges
        mysql --defaults-extra-file=$dbconf -e "FLUSH PRIVILEGES"
    fi

done
# remove .cnf file after usage
rm -f /catapult/provisioners/redhat/installers/${1}.cnf
end=$(date +%s)
echo -e "\n==> completed in ($(($end - $start)) seconds)"


provisionend=$(date +%s)
echo -e "\n\n\n==> Provision complete ($(($provisionend - $provisionstart)) total seconds)"


exit 0