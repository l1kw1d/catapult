source "/catapult/provisioners/redhat/modules/catapult.sh"



if ([ "${4}" == "apache" ] || [ "${4}" == "mysql" ]); then
    echo -e "\n> configuring daily cron task: git gc"
    touch "/etc/cron.daily/catapult-git.cron"
    cat "/catapult/provisioners/redhat/modules/cron_git.sh" > "/etc/cron.daily/catapult-git.cron"
    chmod 755 "/etc/cron.daily/catapult-git.cron"
fi



if [ "${4}" == "mysql" ]; then
    echo -e "\n> configuring daily cron task: mysql check"
    # ref: https://mariadb.com/kb/en/mariadb/mysqlcheck/
    touch "/etc/cron.daily/catapult-mysql.cron"
    cat "/catapult/provisioners/redhat/modules/cron_mysql.sh" > "/etc/cron.daily/catapult-mysql.cron"
    chmod 755 "/etc/cron.daily/catapult-mysql.cron"
    # remove task from previous implemenation
    rm -f "/etc/cron.daily/catapult-mysql"
fi



echo -e "\n> configuring weekly cron task: system reboot"
touch "/etc/cron.weekly/catapult-reboot.cron"
cat "/catapult/provisioners/redhat/modules/cron_reboot.sh" > "/etc/cron.weekly/catapult-reboot.cron"
chmod 755 "/etc/cron.weekly/catapult-reboot.cron"
# remove task from previous implemenation
rm -f "/etc/cron.daily/catapult-reboot.cron"



echo -e "\n> anacron configuration"
cat /etc/anacrontab

echo -e "\n> cron hourly"
ls /etc/cron.hourly/

echo -e "\n> cron daily"
ls /etc/cron.daily/

echo -e "\n> cron weekly"
ls /etc/cron.weekly/

echo -e "\n> cron monthly"
ls /etc/cron.monthly/

echo -e "\n> cron log"
tail /var/log/cron
