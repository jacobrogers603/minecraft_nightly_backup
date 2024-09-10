# Minecraft Server Backup Script

This ps1 script will backup a minecraft server to a different location.

A backup folder will be made in a the target directory with the name of the *<currentDate>_backup_<serverDirName>*

*Optionally, a **scheduled task** made with the windows task scheduler could call this script periodically*

## Prerequistes

1. This assumes the server is running on an **nssm** service that calls a batch file to start the server
2. This assumes the server has **rcon enabled** and that you have **mcrcon installed** on your machine [link to github release](https://github.com/Tiiffi/mcrcon)

## parameters

- `serverPath`: the path to the folder that contains all your minecraft server files
- `backupPath`: the path to the folder where you want the backup folders to be created
- `rconPassword`: your password for rcon (set in the server.properties file)
- `serverIp` (optional; default = "localhost"): the ip address to the server
- `nssmServiceName`: the name of the nssm service you defined to run your minecraft server (from a batch file)
- `warningMode` (optional; default = true): whether or not to give the players in the server a five minute warning via log messages sent by rcon before the server shuts down for the backup process
