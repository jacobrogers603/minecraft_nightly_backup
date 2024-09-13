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
- `serverIp (optional; default = "localhost")`: the ip address to the server
- `nssmServiceName`: the name of the nssm service you defined to run your minecraft server (from a batch file)

## (optional) Windows task scheduler

Make a task in the task scheduler to run the script daily

- set user as yourself, you can press the search button and type your windows user name for the computer
- set to run whether user is logged on or not
- check "Run with highest privileges"
- set a trigger to run daily at 4am in the Triggers tab
- In the Actions tab, make a new action with these settings:
    - program/script: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
    - Add arguments: `C:\<pathToScriptLocation\script.ps1> -serverPath '<pathToServer>' -backupPath '<pathToBackupLocation>' -rconPassword '<rconPassword>' -serverIp '<localhost>' -nssmServiceName '<nssmServiceName>'`
    - Start in: `C:\<pathToScriptLocation>`

*Sometimes after making the task you need to restart the computer in order for it to start working*