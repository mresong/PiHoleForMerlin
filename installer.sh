#!/opt/bin/bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2015, 2016 by Jacob Salmela
# Network-wide ad blocking via your Raspberry Pi
# http://pi-hole.net
# Installs Pi-hole
#
# Pi-hole is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.

# piholeDebug.sh is not installed.  It does not work because dnsmasq is in wierd places
# updateDashboard.sh is not installed.  To update pihole and dashboard use this script.  
# setupLCD.sh is not installed

#TO DO
# sqlite3

#Set this to an IP different than your router and not in your dhcp range
IPHOLE="192.168.1.254"

#Set this to your tz
TZ="America/Los_Angeles"

spinner()
{
    local pid=$1
    local delay="1s"
    local spinstr='/-\|'
    while [ "$(ps | awk '{print $1}' | grep "$pid")" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=${temp}${spinstr%"$temp"}
        sleep ${delay}
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

installDependencies() {
    echo ":::"
    echo "::: Installing Dependencies"

    PIHOLE_DEPS=( 
        bc bash curl git git-http sed rsync perl python3 python3-sqlite3 procps-ng-pgrep logrotate sqlite3-cli
	coreutils-date coreutils-mktemp coreutils-tail coreutils-truncate net-tools-hostname
	php5-fastcgi php5-mod-json php5-mod-openssl php5-mod-session
	lighttpd lighttpd-mod-fastcgi lighttpd-mod-access lighttpd-mod-accesslog lighttpd-mod-expire 
	lighttpd-mod-compress lighttpd-mod-redirect lighttpd-mod-rewrite lighttpd-mod-setenv
    )

    for i in "${PIHOLE_DEPS[@]}"; do
        opkg install "$i"
    done

    echo "!!! done."
}

createBridge() {
echo ":::"
echo "::: Creating Bridge Interface"
    
FILE=/jffs/scripts/services-start
touch "$FILE"
chmod +x "$FILE"
grep -q "$IPHOLE" "$FILE" || echo '

#Setup bridge for PiHole
ifconfig br0:1 '$IPHOLE' netmask 255.255.255.0 up

' >> "$FILE"

source "$FILE"

echo "!!! done."
}

setupPhpTZ() {
    echo ":::"
    echo "::: Setup php.ini with correct TZ..."
    #TZ=$(cut -f1 -d "," /opt/etc/TZ)
    sed -i "s|.*date.timezone.*|date.timezone = $TZ|" /opt/etc/php.ini
    echo "!!! done."
}

setupDnsmasq() {
echo ":::"
echo "::: Creating dnsmasq configuration"

FILE=/jffs/configs/dnsmasq.conf.add
touch "$FILE"
grep -q "pihole" "$FILE" || echo '

# Set dnsmasq configs for PiHole
log-queries
log-async
log-facility=/opt/var/log/pihole.log
addn-hosts=/opt/etc/pihole/gravity.list
'  >> "$FILE"

service restart_dnsmasq >> /dev/null

echo "!!! done."
}

setupLighttpd() {
echo ":::"
echo "::: Creating lighttpd configuration"

#Setup cache dir for compress
mkdir -p /tmp/lighttpd/compress
sed -i 's|cache_dir|"/tmp/lighttpd"|g' /opt/etc/lighttpd/conf.d/30-compress.conf

FILE=/opt/etc/lighttpd/conf.d/40-pihole.conf
touch "$FILE"
grep -q "pihole" "$FILE" || echo '

server.bind = "'$IPHOLE'"
server.error-handler-404	= "pihole/index.html"

accesslog.filename			= "/opt/var/log/lighttpd/access.log"
accesslog.format			= "%{%s}t|%V|%r|%s|%b"

fastcgi.server = (
  ".php" =>
    ( "localhost" =>
      ( "socket" => "/tmp/php-fcgi.sock",
        "bin-path" => "/opt/bin/php-fcgi",
        "max-procs" => 1,
        "bin-environment" =>
          ( "PHP_FCGI_CHILDREN" => "2",
             "PHP_FCGI_MAX_REQUESTS" => "1000"
          )
      )
    )
)

# If the URL starts with /admin, it is the Web interface
$HTTP["url"] =~ "^/admin/" {
    # Create a response header for debugging using curl -I
    setenv.add-response-header = (
        "X-Pi-hole" => "The Pi-hole Web interface is working!",
        "X-Frame-Options" => "DENY"
    )
}

# If the URL does not start with /admin, then it is a query for an ad domain
$HTTP["url"] =~ "^(?!/admin)/.*" {
    # Create a response header for debugging using curl -I
    setenv.add-response-header = ( "X-Pi-hole" => "A black hole for Internet advertisements." )
    # rewrite only js requests
    url.rewrite = ("(.*).js" => "pihole/index.js")
}

$HTTP["host"] =~ "ads.hulu.com|ads-v-darwin.hulu.com|ads-e-darwin.hulu.com" {
	url.redirect = ( "^/published/(.*)" => "http://192.168.1.1:8200/MediaItems/pi-hole.mov")
}

' >> "$FILE"

/opt/etc/init.d/S80lighttpd restart

echo "!!! done."
}

webInterfaceGitUrl="https://github.com/pi-hole/AdminLTE.git"
webInterfaceGitBranch="devel"
webInterfaceDir="/opt/etc/.pihole_admin"
piholeGitUrl="https://github.com/pi-hole/pi-hole.git"
piholeGitBranch="master"
piholeFilesDir="/opt/etc/.pihole"

getGitFiles() {
    # Setup git repos for base files and web admin
    echo ":::"
    echo "::: Checking for existing base files..."
    if is_repo ${piholeFilesDir}; then
        make_repo ${piholeFilesDir} ${piholeGitUrl}
    else
        update_repo ${piholeFilesDir} ${piholeGitBranch}
    fi

    echo ":::"
    echo "::: Checking for existing web interface..."
    if is_repo ${webInterfaceDir}; then
        make_repo ${webInterfaceDir} ${webInterfaceGitUrl}
    else
        update_repo ${webInterfaceDir} ${webInterfaceGitBranch}
    fi
}

is_repo() {
    # If the directory does not have a .git folder it is not a repo
    echo -n ":::    Checking $1 is a repo..."
        if [ -d "$1/.git" ]; then
            echo " OK!"
            return 1
        fi
    echo " not found!!"
    return 0
}

make_repo() {
    # Remove the non-repod interface and clone the interface
    echo -n ":::    Cloning $2 into $1..."
    rm -rf "$1"
    git clone -q "$2" "$1" > /dev/null & spinner $!
    echo " done!"
}

update_repo() {
    # Pull the latest commits
    echo ":::     Updating repo in $1..."
    cd "$1" || exit
    git checkout "$2"
    git pull -q > /dev/null & spinner $!
    echo " done!"
}

installScripts() {
    # Install the scripts from /opt/etc/.pihole to their various locations
    echo ":::"
    echo "::: Installing scripts to /opt/pihole..."
    
    mkdir -p /opt/pihole		

    cp /opt/etc/.pihole/pihole /opt/pihole/pihole
    cp /opt/etc/.pihole/gravity.sh /opt/pihole/gravity.sh
    cp /opt/etc/.pihole/advanced/Scripts/chronometer.sh /opt/pihole/chronometer.sh
    cp /opt/etc/.pihole/advanced/Scripts/whitelist.sh /opt/pihole/whitelist.sh
    cp /opt/etc/.pihole/advanced/Scripts/blacklist.sh /opt/pihole/blacklist.sh
    cp /opt/etc/.pihole/advanced/Scripts/version.sh /opt/pihole/version.sh

    #make everything executable
    chmod +x /opt/pihole/*.sh

    #everything in /var/www/html is actually in /opt/share/www
    sed -i 's|/var/www/html|/opt/share/www|g' /opt/pihole/*

    #everything in /etc is actually in /opt/etc
    sed -i 's|\\\/etc\\\/|\\\/opt\\\/etc\\\/|g' /opt/pihole/*
    sed -i 's|/etc/|/opt/etc/|g' /opt/pihole/*

    #everything in /var is actually in /opt/var
    sed -i 's|\\\/var\\\/|\\\/opt\\\/var\\\/|g' /opt/pihole/*
    sed -i 's|/var/|/opt/var/|g' /opt/pihole/*

    #bash is in /opt/bin/bash
    sed -i 's|/bin/bash|/opt/bin/bash|g' /opt/pihole/*

    #in the gravity.sh script don't run gravity_reload function.
    #it doesn't work with our dnsmasq setup
    sed -e '/^gravity_reload/ s/^#*/#/' -i /opt/pihole/gravity.sh
    #instead just restart dnsmasq
    echo 'service restart_dnsmasq' >> gravity.sh

    #remove functionality from pihole that does not work correctly
    sed -e '/-ud.*updateDashboard/ s/^#*/#/' -i /opt/pihole/pihole
    sed -e '/-up.*updatePihole/ s/^#*/#/' -i /opt/pihole/pihole
    sed -e '/-s.*setupLCD/ s/^#*/#/' -i /opt/pihole/pihole
    sed -e '/-d.*debug/ s/^#*/#/' -i /opt/pihole/pihole

    #fix version.sh
    sed -i 's/grep.*)/grep tag_name | cut -d ":" -f 2 | tr -d "\\\" ,")/g' /opt/pihole/version.sh
    sed -i 's|/opt/share/www/admin|/opt/etc/.pihole_admin|g' /opt/pihole/version.sh

    #link pihole to something in our path
    ln -sf /opt/pihole/pihole /opt/usr/sbin/pihole

    echo "!!! done."
}

installAdmin() {
    echo ":::"
    echo -n "::: Installing Admin to /opt/share/www/admin..."

    mkdir -p /opt/share/www/admin
    rsync -a --exclude=".git*" /opt/etc/.pihole_admin/ /opt/share/www/admin/ > /dev/null & spinner $!

    #everything in /etc is actually in /opt/etc
    find /opt/share/www/admin/ -type f -exec sed -i -e 's|/etc|/opt/etc|g' {} \; > /dev/null & spinner $!

    #everything in /var is actually in /opt/var
    find /opt/share/www/admin/ -type f -exec sed -i -e 's|/var|/opt/var|g' {} \; > /dev/null & spinner $!

    #fix bug in script data.php
    sed -i '/function getAllQueries() {/a \ \ \ \ \ \ \ \ \$status = ""; ' /opt/share/www/admin/data.php

    #enable php debug
    echo "error_reporting = E_ALL"      > /opt/share/www/admin/.user.ini
    echo "display_errors = On"         >> /opt/share/www/admin/.user.ini
    echo "html_errors = On"            >> /opt/share/www/admin/.user.ini
    echo "display_startup_errors = On" >> /opt/share/www/admin/.user.ini
    echo "log_errors = On"             >> /opt/share/www/admin/.user.ini

    echo "!!! done."    
}

installPiholeMov() {
    echo ":::"
    echo -n "::: Installing pi-hole movie..."
    curl -s -o /opt/pihole/pi-hole.mov http://jacobsalmela.com/wp-content/uploads/2014/10/pi-hole.mov > /dev/null & spinner $!
    echo " done."
}

createPiholeIpFile() {
    echo ":::"
    echo "::: Create PiHole Ip file..."
    mkdir -p /opt/etc/pihole
    echo "$IPHOLE" > /opt/etc/pihole/piholeIP
    echo "!!! done."
}

createPiholeSetupVarsFile() {
    echo ":::"
    echo "::: Create PiHole setupVars.conf file..."
    mkdir -p /opt/etc/pihole
    
    echo 'IPv4addr="'$IPHOLE'"'     > /opt/etc/pihole/setupVars.conf
    echo 'piholeInterface="br0:0"' >> /opt/etc/pihole/setupVars.conf
    echo 'piholeIPv6=""'           >> /opt/etc/pihole/setupVars.conf
    echo 'piholeDNS1=""'           >> /opt/etc/pihole/setupVars.conf
    echo 'piholeDNS2=""'           >> /opt/etc/pihole/setupVars.conf
    
    echo "!!! done."
}

createDummyHostnameFile() {
    echo ":::"
    echo "::: Create dummy Host file..."
    echo "pi.hole" > /opt/etc/hostname
    echo "!!! done."
}

createLogFile() {
    # Create logfiles if necessary
    echo ":::"
    echo "::: Creating log file and changing owner to nobody..."
    touch /opt/var/log/pihole.log
    chmod 644 /opt/var/log/pihole.log
    chown nobody:root /opt/var/log/pihole.log
    echo "::: done!"
}

setupLogrotate() {
echo ":::"
echo "::: configure logrotate for dnsmasq..."

FILE=/opt/etc/logrotate.d/pihole
touch "$FILE"
grep -q "pihole" "$FILE" || echo '
/opt/var/log/pihole.log {
    daily
    missingok
    rotate 2
    notifempty
    compress
    sharedscripts
    postrotate
        [ ! -f /var/run/dnsmasq.pid ] || kill -USR2 $(cat /var/run/dnsmasq.pid)
    endscript
    create 0644 nobody root
}
' > "$FILE"
chmod 0644 "$FILE"

FILE=/jffs/scripts/init-start
touch "$FILE"
chmod +x "$FILE"
grep -q "logrotate" "$FILE" || echo '

# logrotate
cru a logrotate "0 0 * * * /opt/sbin/logrotate -f /opt/etc/logrotate.conf &>/dev/null"

' >> "$FILE"

echo "!!! done"
}

createPiholeDb() {
echo ":::"
echo "::: create pihole db..."

piholeDb=/opt/etc/pihole/pihole.db

if [ -e $piholeDb ]
then
    echo "::: db already exists..."
else
    tmp="/tmp/pihole.str"

    echo '
    create table ad_domains (domain varchar);
    create table queries (dt datetime, domain varchar, ip varchar(15));
    create table queries_hour(dt datetime, domain varchar, ip varchar(15), count integer);
    create table queries_day(dt datetime, domain varchar, ip varchar(15), count integer);
    create table queries_month(dt datetime, domain varchar, ip varchar(15), count integer);
    create table queries_year(dt datetime, domain varchar, ip varchar(15), count integer);
    CREATE UNIQUE INDEX ad_domains_index ON ad_domains (domain);
    CREATE UNIQUE INDEX queries_hour_index ON queries_hour (dt, domain, ip);
    CREATE UNIQUE INDEX queries_day_index ON queries_day (dt, domain, ip);
    CREATE UNIQUE INDEX queries_month_index ON queries_month (dt, domain, ip);
    CREATE UNIQUE INDEX queries_year_index ON queries_year (dt, domain, ip);
    ' > $tmp

    sqlite3 $piholeDb < $tmp;
    rm -f $tmp
fi
echo "!!! done"
}

installPiholeWeb() {
    # Install the web interface
    echo ":::"
    echo "::: Installing pihole custom index page..."
    mkdir -p /opt/share/www/pihole
    cp /opt/etc/.pihole/advanced/index.* /opt/share/www/pihole/.
    echo "!!! done"
}

installCron() {
echo ":::"
echo "::: Installing Cron Jobs"

FILE=/jffs/scripts/init-start
touch "$FILE"
chmod +x "$FILE"
grep -q "pihole" "$FILE" || echo '

# Pi-hole: Update the ad sources once a week on Sunday at 01:59
cru a UpdateGravity "59 1 * * 7 /opt/pihole/pihole updateGravity"

' >> "$FILE"

echo "!!! done."
}

runGravity() {
    # Rub gravity.sh to build blacklists
    echo ":::"
    echo "::: Preparing to run gravity.sh to refresh hosts..."
    if ls /opt/etc/pihole/list* 1> /dev/null 2>&1; then
        echo "::: Cleaning up previous install (preserving whitelist/blacklist)"
        rm /opt/etc/pihole/list.*
    fi
    echo "::: Running gravity.sh"
    /opt/pihole/gravity.sh
}

installPiHole() {
    installDependencies
    createBridge
    setupPhpTZ
    setupDnsmasq
    setupLighttpd
    getGitFiles
    installScripts
    installAdmin
    installPiholeMov
    createPiholeDb
    createPiholeIpFile
    createPiholeSetupVarsFile
    createDummyHostnameFile
    createLogFile
    setupLogrotate
    installPiholeWeb
    installCron
    runGravity

    echo "::: View the web interface at http://pi.hole/admin or http://$IPHOLE/admin"
}

updatePihole() {
    installDependencies
    getGitFiles
    installScripts
    installAdmin
    installPiholeMov
    installPiholeWeb
    runGravity
}


function helpFunc {
    echo "::: Install PiHole!"
    echo ":::"
    echo "::: Options:"
    echo ":::  -i, install"
    echo ":::  -u, update"
    exit 1
}

if [[ $# = 0 ]]; then
    helpFunc
fi

# Handle redirecting to specific functions based on arguments
case "$1" in
"-i" | "install" ) installPiHole;;
"-u" | "install" ) updatePiHole;;
*                ) helpFunc;;
esac