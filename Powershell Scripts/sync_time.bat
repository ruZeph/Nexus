@echo off

net stop w32time

w32tm /unregister
w32tm /register

net start w32time

w32tm /config /manualpeerlist:"time.google.com,time.cloudflare.com,in.pool.ntp.org" /syncfromflags:manual /update

w32tm /resync /force

pause
