# Minecraft Server Backup Script

This ps1 script will backup a minecraft server to a different location.

A backup folder will be made in a the target directory with the name of the *<currentDate>_backup_<serverDirName>*

*Optionally, a **scheduled task** made with the windows task scheduler could call this script periodically*

## Prerequistes

1. This assumes the server is running on an **nssm** service that calls a batch file to start the server
2. This assumes the server has rcon enabled and you have the rcon-cli installed globally on your machine (you need node.js for this)

## parameters

- `serverPath`: the path to the folder that contains all your minecraft server files
- `backupPath`: the path to the folder where you want the backup folders to be created
- `rconPassword`: your password for rcon (set in the server.properties file)
- `serverIp`: the ip address to the server
- `nssmServiceName`: the name of the nssm service you defined to run your minecraft server (from a batch file)
